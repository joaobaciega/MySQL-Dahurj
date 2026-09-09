"""
Importador da base de verbas: Excel -> MySQL (tabelas `vendas_verbas` e
`verbas_pagamentos`, que alimentam a aba "Verbas" do dashboard).

É o passo semanal: toda sexta você atualiza a planilha "Base de dados para Dash
Board.xlsx" (vendas novas entram no topo, as fórmulas recalculam) e roda este
script. Ele não faz merge — APAGA e regrava `vendas_verbas` inteira dentro de uma
transação, porque o Excel é a fonte da verdade. Rodar duas vezes dá exatamente o
mesmo resultado.

Abas lidas da planilha:
    Total       vendas linha a linha (uma linha por produto dentro de um pedido)
    Verbas      auxiliar: código do produto -> Unidade (Par = dianteiro,
                Unitário = traseiro). Cabeçalho na LINHA 2.
    Pagamentos  auxiliar: quais meses já tiveram verba de consultor/gerente paga.
                Se a aba não existir, o script preserva o que já está no banco e
                avisa — nunca zera em silêncio.

Destinos: por padrão grava em TODAS as seções de banco encontradas no
.streamlit/secrets.toml — `[mysql]` (local) e `[mysql_online]` (Streamlit Cloud).
Assim uma rodada só atualiza os dois ambientes. Sem secrets.toml, cai nas
variáveis de ambiente DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME.

Pré-requisito: as tabelas precisam existir — rode antes, uma única vez,
`alteracoes no sql/add_verbas.sql` (ou o schema.sql completo).

Uso:
    python importar_verbas.py                          # xlsx padrão, todos os destinos
    python importar_verbas.py "outra base.xlsx"
    python importar_verbas.py --destino online         # só o banco online
    python importar_verbas.py --destino local
"""

import argparse
import os
import re
import sys
import unicodedata
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

BASE_DIR = Path(__file__).resolve().parent
EXCEL_PADRAO = BASE_DIR / "Base de dados para Dash Board.xlsx"

ABA_VENDAS = "Total"
ABA_PRODUTOS = "Verbas"
ABA_PAGAMENTOS = "Pagamentos"

# Colunas da aba `Total`, na ordem A..O. Q ("Total Verbas") é ignorada: é só a
# soma das outras três e seria um número redundante para manter em sincronia.
COLS = {
    "Data": "data",
    "N° Pedido": "pedido",
    "CNPJ - CPF": "cnpj",
    "Cliente": "cliente",
    "Código": "codigo",
    "Produto": "produto",
    "Preço Unit. R$": "preco_unit",
    "Qtde": "qtde",
    "Total Item R$": "total_item",
    "Verba Consultor": "verba_consultor",
    "Total Consultor": "total_consultor",
    "Verba Gerente": "verba_gerente",
    "Total Gerente": "total_gerente",
    "Reserva": "verba_reserva",
    "Total Reserva": "total_reserva",
}

# "Par" é o refil dianteiro (vendido aos pares), "Unitário" é o traseiro.
TIPO_POR_UNIDADE = {"PAR": "diant", "UNITARIO": "tras"}

# Aceitos como "sim" na aba Pagamentos — a planilha é preenchida à mão, então vale
# tolerar as formas que aparecem naturalmente.
VERDADEIROS = {"SIM", "S", "X", "1", "TRUE", "VERDADEIRO", "PAGO", "OK"}

CENTAVO = 0.01   # tolerância das conferências: divergência de arredondamento


# --------------------------------------------------------------------------
# Conexão
# --------------------------------------------------------------------------
def _url(cfg):
    return URL.create(
        "mysql+pymysql",
        username=cfg["user"],
        password=cfg["password"],
        host=cfg.get("host", "127.0.0.1"),
        port=int(cfg.get("port", 3306)),
        database=cfg["database"],
        query={"charset": "utf8mb4"},
    )


def destinos(filtro=None):
    """Bancos onde gravar, como [(rótulo, cfg)].

    Lê as seções `[mysql]` e `[mysql_online]` do .streamlit/secrets.toml — o mesmo
    arquivo que o app usa, para não haver duas fontes de credencial. Sem o
    arquivo (ou sem a seção pedida), usa as variáveis de ambiente.
    """
    achados = []
    secrets = BASE_DIR / ".streamlit" / "secrets.toml"
    if secrets.exists():
        import tomllib
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
            raise SystemExit(
                f"Destino '{filtro}' não encontrado. Para gravar no banco online, "
                f"acrescente uma seção [mysql_online] em {secrets} com host/port/"
                "user/password/database do Streamlit Cloud."
            )
    return achados


# --------------------------------------------------------------------------
# Leitura do Excel
# --------------------------------------------------------------------------
def _norm_codigo(v):
    """Código do produto comparável: 'AT 800', 'AT800' e o número 63750 (que o
    Excel devolve como int ou float) precisam colidir na mesma chave."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return re.sub(r"[^A-Z0-9]", "", str(v).upper())


def _norm_texto(v):
    """Texto comparável: sem acento, sem espaço, maiúsculo.

    O NFKD antes do filtro é o que importa aqui — sem ele 'Unitário' viraria
    'UNITRIO' (o Á cai fora de A-Z) e nenhum refil traseiro seria classificado.
    """
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return ""
    sem_acento = unicodedata.normalize("NFKD", str(v))
    sem_acento = "".join(c for c in sem_acento if not unicodedata.combining(c))
    return re.sub(r"[^A-Z]", "", sem_acento.upper())


def ler_tipos_produto(path):
    """Mapa código normalizado -> 'diant'/'tras', da aba auxiliar `Verbas`.

    O cabeçalho dessa aba está na linha 2 da planilha (a linha 1 é vazia), daí o
    header=1.
    """
    df = pd.read_excel(path, sheet_name=ABA_PRODUTOS, header=1)
    faltando = {"Código", "Unidade"} - set(df.columns)
    if faltando:
        raise SystemExit(
            f"A aba '{ABA_PRODUTOS}' não tem as colunas {sorted(faltando)}. "
            "Esperado o cabeçalho na linha 2, com 'Código' e 'Unidade'."
        )
    tipos = {}
    for _, r in df.iterrows():
        cod = _norm_codigo(r["Código"])
        tipo = TIPO_POR_UNIDADE.get(_norm_texto(r["Unidade"]))
        if cod and tipo:
            tipos[cod] = tipo
    return tipos


def ler_vendas(path, tipos):
    """Aba `Total` já limpa e com as colunas renomeadas para as do banco."""
    df = pd.read_excel(path, sheet_name=ABA_VENDAS)
    faltando = set(COLS) - set(df.columns)
    if faltando:
        raise SystemExit(
            f"A aba '{ABA_VENDAS}' não tem as colunas {sorted(faltando)}. "
            "Confira se o cabeçalho continua na linha 1."
        )
    df = df[list(COLS)].rename(columns=COLS)

    # Linhas sem data são o rodapé/linhas em branco da planilha, não vendas.
    df["data"] = pd.to_datetime(df["data"], errors="coerce")
    descartadas = int(df["data"].isna().sum())
    df = df[df["data"].notna()].copy()

    df["pedido"] = df["pedido"].apply(
        lambda v: str(int(v)) if isinstance(v, float) and v.is_integer() else str(v).strip()
    )
    for c in ("cnpj", "cliente", "produto"):
        df[c] = df[c].fillna("").astype(str).str.strip()
    df["codigo"] = df["codigo"].apply(
        lambda v: str(int(v)) if isinstance(v, float) and v.is_integer() else str(v).strip()
    )
    df["tipo_refil"] = df["codigo"].apply(lambda c: tipos.get(_norm_codigo(c)))

    df["qtde"] = pd.to_numeric(df["qtde"], errors="coerce").fillna(0).astype(int)
    # astype(float) é proposital: colunas com valores redondos viriam como int64,
    # e numpy.int64 não é subclasse de int — o pymysql não sabe escapá-lo.
    for c in ("preco_unit", "total_item", "verba_consultor", "total_consultor",
              "verba_gerente", "total_gerente", "verba_reserva", "total_reserva"):
        df[c] = pd.to_numeric(df[c], errors="coerce").fillna(0.0).round(2).astype(float)

    return df, descartadas


def ler_pagamentos(path):
    """Meses com verba já paga, da aba `Pagamentos`.

    Devolve None (não uma lista vazia) quando a aba não existe: quem chama precisa
    distinguir "não informado, preserve o banco" de "informado e vazio".
    """
    try:
        df = pd.read_excel(path, sheet_name=ABA_PAGAMENTOS)
    except ValueError:                       # aba inexistente
        return None

    faltando = {"Mês", "Consultor Pago", "Gerente Pago"} - set(df.columns)
    if faltando:
        raise SystemExit(
            f"A aba '{ABA_PAGAMENTOS}' não tem as colunas {sorted(faltando)}.\n"
            "Layout esperado (cabeçalho na linha 1):\n"
            "    Mês        | Consultor Pago | Gerente Pago\n"
            "    01/01/2026 | Não            | Não"
        )

    def flag(v):
        return 1 if _norm_texto(v) in VERDADEIROS or str(v).strip() in {"1", "1.0"} else 0

    df["Mês"] = pd.to_datetime(df["Mês"], errors="coerce")
    linhas = []
    for _, r in df[df["Mês"].notna()].iterrows():
        # Normaliza para o 1º dia do mês: a planilha pode trazer qualquer dia.
        linhas.append({
            "mes": r["Mês"].date().replace(day=1),
            "consultor_pago": flag(r["Consultor Pago"]),
            "gerente_pago": flag(r["Gerente Pago"]),
        })
    return linhas


# --------------------------------------------------------------------------
# Gravação
# --------------------------------------------------------------------------
CAMPOS = ["data", "pedido", "cnpj", "cliente", "codigo", "produto", "tipo_refil",
          "preco_unit", "qtde", "total_item", "verba_consultor", "total_consultor",
          "verba_gerente", "total_gerente", "verba_reserva", "total_reserva"]

INSERT_VENDAS = text(
    f"INSERT INTO vendas_verbas ({', '.join(CAMPOS)}) "
    f"VALUES ({', '.join(':' + c for c in CAMPOS)})"
)

UPSERT_PAGAMENTOS = text("""
    INSERT INTO verbas_pagamentos (mes, consultor_pago, gerente_pago)
    VALUES (:mes, :consultor_pago, :gerente_pago)
    ON DUPLICATE KEY UPDATE
        consultor_pago = VALUES(consultor_pago),
        gerente_pago   = VALUES(gerente_pago)
""")


def gravar(cfg, vendas, pagamentos):
    """Regrava a base de verbas num destino. Tudo numa transação só.

    `eng.begin()` abre transação e dá COMMIT explícito no fim — necessário porque
    o banco online roda com autocommit desligado, e sem isso o DELETE/INSERT
    ficaria pendurado sem efeito.
    """
    eng = create_engine(_url(cfg), pool_pre_ping=True)
    registros = vendas[CAMPOS].to_dict("records")
    for r in registros:
        r["data"] = r["data"].date()          # pymysql não aceita Timestamp
        r["qtde"] = int(r["qtde"])            # nem numpy.int64
        if pd.isna(r["tipo_refil"]):          # NaN viraria a string 'nan' no ENUM
            r["tipo_refil"] = None

    with eng.begin() as conn:
        conn.execute(text("DELETE FROM vendas_verbas"))
        if registros:
            conn.execute(INSERT_VENDAS, registros)
        if pagamentos is not None:
            conn.execute(text("DELETE FROM verbas_pagamentos"))
            if pagamentos:
                conn.execute(UPSERT_PAGAMENTOS, pagamentos)
    return eng


def conferir(eng, vendas):
    """Compara o que o banco somou com o que o Excel trazia. Imprime OK/DIVERGÊNCIA
    por métrica e devolve True se tudo bateu."""
    with eng.connect() as conn:
        row = conn.execute(text("""
            SELECT COUNT(*)                        AS linhas,
                   COUNT(DISTINCT pedido)          AS pedidos,
                   COALESCE(SUM(total_item), 0)      AS fat,
                   COALESCE(SUM(total_consultor), 0) AS consultor,
                   COALESCE(SUM(total_gerente), 0)   AS gerente,
                   COALESCE(SUM(total_reserva), 0)   AS marketing
            FROM vendas_verbas
        """)).mappings().one()
        pagos = conn.execute(text(
            "SELECT COUNT(*) FROM verbas_pagamentos "
            "WHERE consultor_pago = 1 OR gerente_pago = 1"
        )).scalar()

    esperado = {
        "linhas": len(vendas),
        "faturamento": round(float(vendas["total_item"].sum()), 2),
        "verba consultor": round(float(vendas["total_consultor"].sum()), 2),
        "verba gerente": round(float(vendas["total_gerente"].sum()), 2),
        "verba marketing": round(float(vendas["total_reserva"].sum()), 2),
    }
    obtido = {
        "linhas": int(row["linhas"]),
        "faturamento": round(float(row["fat"]), 2),
        "verba consultor": round(float(row["consultor"]), 2),
        "verba gerente": round(float(row["gerente"]), 2),
        "verba marketing": round(float(row["marketing"]), 2),
    }

    ok = True
    for k in esperado:
        e, o = esperado[k], obtido[k]
        bate = (e == o) if k == "linhas" else abs(e - o) <= CENTAVO
        ok = ok and bate
        molde = "{:>16}: banco {:>14}  excel {:>14}   {}"
        if k == "linhas":
            print(molde.format(k, o, e, "OK" if bate else "DIVERGÊNCIA"))
        else:
            print(molde.format(k, _brl(o), _brl(e), "OK" if bate else "DIVERGÊNCIA"))
    print(f"{'pedidos':>16}: {row['pedidos']}")
    print(f"{'meses pagos':>16}: {pagos}")
    return ok


def _brl(v):
    return ("R$ {:,.2f}".format(v)).replace(",", "X").replace(".", ",").replace("X", ".")


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Importa a base de verbas do Excel para o MySQL.")
    ap.add_argument("excel", nargs="?", default=str(EXCEL_PADRAO),
                    help="caminho da planilha (padrão: Base de dados para Dash Board.xlsx)")
    ap.add_argument("--destino", choices=["local", "online", "env"], default=None,
                    help="grava só num destino (padrão: todos os configurados)")
    args = ap.parse_args()

    caminho = Path(args.excel)
    if not caminho.exists():
        raise SystemExit(f"Planilha não encontrada: {caminho}")

    print(f"Planilha: {caminho.name}")
    tipos = ler_tipos_produto(caminho)
    vendas, descartadas = ler_vendas(caminho, tipos)
    pagamentos = ler_pagamentos(caminho)

    print(f"  {len(vendas)} vendas lidas da aba '{ABA_VENDAS}'"
          + (f" ({descartadas} linha(s) sem data ignorada(s))" if descartadas else ""))

    sem_tipo = vendas[vendas["tipo_refil"].isna()]
    if not sem_tipo.empty:
        codigos = sorted(sem_tipo["codigo"].unique())
        print(f"  AVISO: {len(sem_tipo)} linha(s) com código fora da aba "
              f"'{ABA_PRODUTOS}': {codigos}. Entram no faturamento e nas verbas, "
              "mas ficam fora da contagem de refil dianteiro/traseiro.")

    if pagamentos is None:
        print(f"  AVISO: aba '{ABA_PAGAMENTOS}' não encontrada — o controle de "
              "meses pagos no banco fica como está. Layout esperado:")
        print("         Mês        | Consultor Pago | Gerente Pago")
        print("         01/01/2026 | Não            | Não")
    else:
        marcados = sum(1 for p in pagamentos if p["consultor_pago"] or p["gerente_pago"])
        print(f"  {len(pagamentos)} mês(es) na aba '{ABA_PAGAMENTOS}', {marcados} com verba paga")

    tudo_ok = True
    for rotulo, cfg in destinos(args.destino):
        print(f"\n--- Gravando em '{rotulo}' ({cfg.get('host')}/{cfg['database']}) ---")
        try:
            eng = gravar(cfg, vendas, pagamentos)
        except Exception as e:
            tudo_ok = False
            print(f"  FALHOU: {e}")
            print("  Nada foi alterado neste destino (a transação sofreu rollback).")
            continue
        tudo_ok = conferir(eng, vendas) and tudo_ok

    print("\n" + ("Importação concluída." if tudo_ok else
                  "Importação terminou COM PENDÊNCIAS — revise as mensagens acima."))
    return 0 if tudo_ok else 1


if __name__ == "__main__":
    sys.exit(main())
