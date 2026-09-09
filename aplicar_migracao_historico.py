"""
Aplica a migração do HISTÓRICO DE LANÇAMENTOS nos bancos configurados.

Roda `alteracoes no sql/add_historico_lancamentos.sql`, que cria a tabela
`lancamentos_historico`, a view `vw_lancamentos_historico` e faz o backfill dos
lançamentos que já existem. A migração é idempotente: rodar de novo não duplica
nada e não altera contagem.

POR QUE UM SCRIPT E NÃO COLAR O SQL NA MÃO
    No banco online (Aiven) o autocommit vem desligado. O SQL colado no console
    executa, mas fica pendente e some quando a sessão cai. Aqui cada statement
    roda dentro de `with eng.begin()`, que faz COMMIT explícito.

Destinos: as seções [mysql] (local) e [mysql_online] (online) de
`.streamlit/secrets.toml`, mesma convenção de `carregar_base.py` e
`importar_verbas.py`. Sem o arquivo, cai nas variáveis de ambiente
DB_HOST / DB_PORT / DB_USER / DB_PASSWORD / DB_NAME.

Uso:
    python aplicar_migracao_historico.py                  # todos os destinos
    python aplicar_migracao_historico.py --destino local
    python aplicar_migracao_historico.py --destino online
    python aplicar_migracao_historico.py --conferir       # não grava, só confere
"""

import argparse
import os
import sys
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

try:
    import tomllib
except ModuleNotFoundError:          # Python < 3.11
    import tomli as tomllib

BASE_DIR = Path(__file__).resolve().parent
SQL_PADRAO = BASE_DIR / "alteracoes no sql" / "add_historico_lancamentos.sql"


# --------------------------------------------------------------------------
# Destinos (mesma convenção do carregar_base.py: uma fonte de credencial só)
# --------------------------------------------------------------------------
def _url(cfg):
    return URL.create(
        "mysql+pymysql",
        username=cfg["user"], password=cfg["password"],
        host=cfg.get("host", "127.0.0.1"), port=int(cfg.get("port", 3306)),
        database=cfg["database"], query={"charset": "utf8mb4"},
    )


def destinos(filtro=None):
    achados = []
    secrets = BASE_DIR / ".streamlit" / "secrets.toml"
    if secrets.exists():
        with open(secrets, "rb") as fh:
            cfg = tomllib.load(fh)
        for secao, rotulo in (("mysql", "local"), ("mysql_online", "online")):
            if secao in cfg:
                achados.append((rotulo, cfg[secao]))
    if not achados:
        achados.append(("env", {
            "host": os.getenv("DB_HOST", "127.0.0.1"),
            "port": int(os.getenv("DB_PORT", "3306")),
            "user": os.getenv("DB_USER", "root"),
            "password": os.getenv("DB_PASSWORD", ""),
            "database": os.getenv("DB_NAME", "dashboard_dahruj"),
        }))
    if filtro:
        achados = [d for d in achados if d[0] == filtro]
        if not achados:
            raise SystemExit(f"Destino '{filtro}' não encontrado em {secrets}.")
    return achados


# --------------------------------------------------------------------------
# Leitura do .sql
# --------------------------------------------------------------------------
def statements(caminho):
    """Quebra o arquivo nos statements executáveis, em ordem.

    O `add_historico_lancamentos.sql` foi escrito de propósito sem PREPARE /
    EXECUTE e sem DELIMITER — são só três comandos idempotentes (CREATE TABLE IF
    NOT EXISTS, CREATE OR REPLACE VIEW, INSERT ... WHERE NOT EXISTS), então um
    split simples por ';' dá conta. Se um dia a migração ganhar SQL dinâmico,
    este parser precisa mudar junto.

    Descarta comentários de linha e o `USE dashboard_dahruj;` — o banco já vem na
    URL de conexão, e o nome pode ser diferente no destino online.
    """
    bruto = Path(caminho).read_text(encoding="utf-8")
    linhas = [ln for ln in bruto.splitlines() if not ln.lstrip().startswith("--")]
    saida = []
    for cmd in "\n".join(linhas).split(";"):
        cmd = cmd.strip()
        if cmd and not cmd.upper().startswith("USE "):
            saida.append(cmd)
    return saida


def _rotulo(cmd):
    """Primeira linha útil do statement, para o log ficar legível."""
    primeira = next((l.strip() for l in cmd.splitlines() if l.strip()), cmd)
    return primeira[:70]


# --------------------------------------------------------------------------
# Conferência (roda antes e depois, para provar o que mudou)
# --------------------------------------------------------------------------
def conferir(conn):
    """Contagens que provam o estado da migração. None = objeto ainda não existe."""
    def _n(sql):
        try:
            return conn.execute(text(sql)).scalar()
        except Exception:
            return None

    return {
        "lancamentos": _n("SELECT COUNT(*) FROM lancamentos"),
        "historico": _n("SELECT COUNT(*) FROM lancamentos_historico"),
        "backfill": _n("SELECT COUNT(*) FROM lancamentos_historico WHERE origem = 'backfill'"),
        "view": _n("SELECT COUNT(*) FROM vw_lancamentos_historico"),
    }


def _mostrar(titulo, c):
    def _v(x):
        return "—(não existe)" if x is None else x
    print(f"    {titulo}: lancamentos={_v(c['lancamentos'])}  "
          f"historico={_v(c['historico'])}  (backfill={_v(c['backfill'])})  "
          f"view={_v(c['view'])}")


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--destino", choices=["local", "online", "env"],
                    help="aplica em um destino só (padrão: todos os configurados)")
    ap.add_argument("--sql", default=str(SQL_PADRAO),
                    help="caminho do .sql (padrão: add_historico_lancamentos.sql)")
    ap.add_argument("--conferir", action="store_true",
                    help="não grava nada: só mostra as contagens atuais")
    args = ap.parse_args()

    caminho = Path(args.sql)
    if not caminho.exists():
        raise SystemExit(f"Arquivo SQL não encontrado: {caminho}")

    cmds = statements(caminho)
    alvos = destinos(args.destino)
    print(f"SQL: {caminho.name}  ({len(cmds)} statement(s))")
    print(f"Destinos: {', '.join(r for r, _ in alvos)}\n")

    problemas = 0
    for rotulo, cfg in alvos:
        print(f"[{rotulo}] {cfg.get('host')}:{cfg.get('port', 3306)}/{cfg['database']}")
        try:
            eng = create_engine(_url(cfg), pool_pre_ping=True)
            with eng.connect() as conn:
                antes = conferir(conn)
            _mostrar("antes ", antes)

            if args.conferir:
                print("    (--conferir: nada foi gravado)\n")
                continue

            for i, cmd in enumerate(cmds, 1):
                # Um begin() por statement: DDL no MySQL já faz commit implícito,
                # então não haveria transação única de qualquer jeito — e assim um
                # erro no meio deixa claro qual passo falhou.
                with eng.begin() as conn:
                    conn.execute(text(cmd))
                print(f"    [{i}/{len(cmds)}] ok — {_rotulo(cmd)}")

            with eng.connect() as conn:
                depois = conferir(conn)
            _mostrar("depois", depois)

            if depois["view"] is None:
                print("    ATENCAO: a view nao respondeu. Investigue antes de usar o app.")
                problemas += 1
            elif depois["view"] != depois["historico"]:
                print("    ATENCAO: view e tabela com contagens diferentes.")
                problemas += 1
            elif depois["historico"] < depois["lancamentos"]:
                print("    ATENCAO: historico menor que lancamentos — backfill incompleto.")
                problemas += 1
            else:
                novas = (depois["historico"] or 0) - (antes["historico"] or 0)
                print(f"    OK — {novas} linha(s) nova(s) no historico.")
            print()
        except Exception as e:
            problemas += 1
            print(f"    FALHOU: {e}\n")

    if problemas:
        print(f"Concluido com {problemas} problema(s). Confira acima.")
        sys.exit(1)
    print("Conferencia concluida (nada gravado)." if args.conferir
          else "Migracao aplicada com sucesso em todos os destinos.")


if __name__ == "__main__":
    main()
