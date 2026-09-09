"""
Carregador da base do dashboard: BASE DAHRUJ.xlsx -> MySQL.

É o novo passo semanal, irmão do `importar_verbas.py`: você atualiza a planilha
`BASE DAHRUJ.xlsx` (cola o acumulado que as lojas mandaram na segunda) e roda
este script. Ele VALIDA a planilha inteira primeiro e só grava se estiver limpa
— não existe carga parcial.

POR QUE FULL REFRESH
    Não faz merge: apaga `lancamentos` e regrava tudo, dentro de uma transação.
    O Excel é a fonte da verdade, então o banco não pode guardar linha que não
    exista mais lá. Rodar duas vezes dá exatamente o mesmo resultado.

O QUE ELE CONGELA NA CARGA
    `preco_diant`, `preco_tras` e `gerente` são resolvidos POR VIGÊNCIA (a linha
    de `dim_preco` / `dim_gerente` válida naquele mês) e gravados em cada
    lançamento. É isso que impede um reajuste de preço, ou um gerente que troca
    de loja, de reescrever mês já fechado.

Abas lidas de `BASE DAHRUJ.xlsx`:
    fato           snapshots acumulados: mes, data_corte, fechado, unidade,
                   consultor, passagens, refil_diant, refil_tras
    dim_unidade    unidade, marca, loja, ativo
    dim_consultor  consultor, unidade_atual, ativo
    dim_gerente    unidade, gerente, vigencia_inicio
    dim_preco      marca, preco_diant, preco_tras, vigencia_inicio

Pré-requisito: rode `schema_v2.sql` uma vez em cada banco.

Uso:
    python carregar_base.py                      # todos os destinos configurados
    python carregar_base.py --so-validar         # não grava nada, só confere
    python carregar_base.py --destino online
    python carregar_base.py "outra base.xlsx"
"""

import argparse
import datetime as dt
import os
import sys
from calendar import monthrange
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

try:
    import tomllib
except ModuleNotFoundError:          # Python < 3.11
    import tomli as tomllib

BASE_DIR = Path(__file__).resolve().parent
EXCEL_PADRAO = BASE_DIR / "BASE DAHRUJ.xlsx"

ABAS = {
    "fato": ["mes", "data_corte", "fechado", "unidade", "consultor",
             "passagens", "refil_diant", "refil_tras"],
    "dim_unidade": ["unidade", "marca", "loja", "ativo"],
    "dim_consultor": ["consultor", "unidade_atual", "ativo"],
    "dim_gerente": ["unidade", "gerente", "vigencia_inicio"],
    "dim_preco": ["marca", "preco_diant", "preco_tras", "vigencia_inicio"],
}


# --------------------------------------------------------------------------
# Destinos (mesma convenção do importar_verbas.py: uma fonte de credencial só)
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
# Leitura
# --------------------------------------------------------------------------
def _txt(v):
    """Texto comparável: NaN -> None e espaço sobrando some. Espaço invisível no
    fim do nome é o erro de colagem mais comum e o mais difícil de enxergar."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return None
    s = str(v).replace(" ", " ").strip()
    return s or None


def _data(v):
    if v is None or pd.isna(v):
        return None
    return pd.Timestamp(v).date()


def _int_ou_none(v):
    """VAZIO -> None (não informado). ZERO -> 0 (informou zero). São diferentes:
    o aproveitamento ignora a linha sem passagens e não pode confundir as duas."""
    if v is None or (isinstance(v, float) and pd.isna(v)) or v == "":
        return None
    return int(round(float(v)))


def _sim(v, padrao="sim"):
    return str(_txt(v) or padrao).strip().lower() in ("sim", "s", "1", "true", "x", "sí")


def ler_excel(path):
    path = Path(path)
    if not path.exists():
        raise SystemExit(f"Planilha não encontrada: {path}")
    xl = pd.ExcelFile(path)
    faltando = [a for a in ABAS if a not in xl.sheet_names]
    if faltando:
        raise SystemExit(f"Abas ausentes na planilha: {', '.join(faltando)}")
    dados = {}
    for aba, cols in ABAS.items():
        d = xl.parse(aba)
        d.columns = [str(c).strip() for c in d.columns]
        ausentes = [c for c in cols if c not in d.columns]
        if ausentes:
            raise SystemExit(f"Aba '{aba}': colunas ausentes {ausentes}. "
                             f"Achei {list(d.columns)}.")
        dados[aba] = d[cols].copy()
    return dados


def normalizar(dados):
    f = dados["fato"]
    f["_linha"] = f.index + 2                    # linha real no Excel
    f = f[~f[ABAS["fato"]].isna().all(axis=1)].copy()
    f["mes"] = f["mes"].map(_data)
    f["data_corte"] = f["data_corte"].map(_data)
    f["fechado"] = f["fechado"].map(lambda v: _sim(v, "nao"))
    for c in ("unidade", "consultor"):
        f[c] = f[c].map(_txt)
    for c in ("passagens", "refil_diant", "refil_tras"):
        f[c] = f[c].map(_int_ou_none)
    f["refil_diant"] = f["refil_diant"].fillna(0).astype(int)
    f["refil_tras"] = f["refil_tras"].fillna(0).astype(int)
    dados["fato"] = f.reset_index(drop=True)

    u = dados["dim_unidade"].dropna(how="all").copy()
    for c in ("unidade", "marca", "loja"):
        u[c] = u[c].map(_txt)
    u["ativo"] = u["ativo"].map(_sim)
    dados["dim_unidade"] = u.reset_index(drop=True)

    c_ = dados["dim_consultor"].dropna(how="all").copy()
    for c in ("consultor", "unidade_atual"):
        c_[c] = c_[c].map(_txt)
    c_["ativo"] = c_["ativo"].map(_sim)
    dados["dim_consultor"] = c_.reset_index(drop=True)

    g = dados["dim_gerente"].dropna(how="all").copy()
    g["unidade"] = g["unidade"].map(_txt)
    g["gerente"] = g["gerente"].map(_txt)
    g["vigencia_inicio"] = g["vigencia_inicio"].map(_data)
    dados["dim_gerente"] = g.reset_index(drop=True)

    p = dados["dim_preco"].dropna(how="all").copy()
    p["marca"] = p["marca"].map(_txt)
    p["vigencia_inicio"] = p["vigencia_inicio"].map(_data)
    for c in ("preco_diant", "preco_tras"):
        p[c] = pd.to_numeric(p[c], errors="coerce")
    dados["dim_preco"] = p.reset_index(drop=True)
    return dados


# --------------------------------------------------------------------------
# Vigência: a linha válida NAQUELE mês
# --------------------------------------------------------------------------
def vigente(tabela, chave_valor, mes, col_chave):
    """Última linha cuja vigencia_inicio <= mes. None se nenhuma cobre o mês."""
    cand = tabela[(tabela[col_chave] == chave_valor)
                  & (tabela["vigencia_inicio"].notna())
                  & (tabela["vigencia_inicio"] <= mes)]
    if cand.empty:
        return None
    return cand.sort_values("vigencia_inicio").iloc[-1]


# --------------------------------------------------------------------------
# Validação — nada é gravado enquanto houver ERRO
# --------------------------------------------------------------------------
def validar(dados, mes_corrente=None):
    erros, avisos = [], []
    f, u = dados["fato"], dados["dim_unidade"]
    dc, dg, dp = dados["dim_consultor"], dados["dim_gerente"], dados["dim_preco"]
    mes_corrente = mes_corrente or dt.date.today().replace(day=1)

    # ---- dimensões: chave repetida, chave vazia, órfã
    for nome, d, chave in (("dim_unidade", u, ["unidade"]),
                           ("dim_consultor", dc, ["consultor"]),
                           ("dim_gerente", dg, ["unidade", "vigencia_inicio"]),
                           ("dim_preco", dp, ["marca", "vigencia_inicio"])):
        if d.empty:
            erros.append(f"{nome}: aba vazia")
            continue
        dup = d[d.duplicated(chave, keep=False)]
        if len(dup):
            erros.append(f"{nome}: chave repetida {chave} -> "
                         f"{sorted({tuple(str(x) for x in r) for r in dup[chave].values})}")
        if d[chave[0]].isna().any():
            erros.append(f"{nome}: linha com '{chave[0]}' vazio")

    if dg["vigencia_inicio"].isna().any():
        erros.append("dim_gerente: linha sem vigencia_inicio")
    if dp["vigencia_inicio"].isna().any():
        erros.append("dim_preco: linha sem vigencia_inicio")
    if dp[["preco_diant", "preco_tras"]].isna().any().any():
        erros.append("dim_preco: preço vazio ou não numérico")

    orfa = set(dg["unidade"].dropna()) - set(u["unidade"].dropna())
    if orfa:
        erros.append(f"dim_gerente aponta unidade fora de dim_unidade: {sorted(orfa)}")
    orfa = set(dc["unidade_atual"].dropna()) - set(u["unidade"].dropna())
    if orfa:
        erros.append(f"dim_consultor.unidade_atual fora de dim_unidade: {sorted(orfa)}")
    orfa = set(u["marca"].dropna()) - set(dp["marca"].dropna())
    if orfa:
        erros.append(f"Marca de dim_unidade sem preço em dim_preco: {sorted(orfa)}")

    if f.empty:
        erros.append("A aba `fato` está vazia.")
        return erros, avisos

    # ---- fato: forma de cada linha
    for _, r in f.iterrows():
        ln = int(r["_linha"])
        if r["mes"] is None:
            erros.append(f"fato linha {ln}: `mes` vazio")
            continue
        if r["mes"].day != 1:
            erros.append(f"fato linha {ln}: `mes` = {r['mes']} — tem que ser o DIA 1")
        if r["data_corte"] is None:
            erros.append(f"fato linha {ln}: `data_corte` vazio")
        else:
            ult = dt.date(r["mes"].year, r["mes"].month,
                          monthrange(r["mes"].year, r["mes"].month)[1])
            if not (r["mes"] <= r["data_corte"] <= ult):
                erros.append(f"fato linha {ln}: `data_corte` {r['data_corte']} fora "
                             f"do mês {r['mes'].strftime('%m/%Y')}")
        if r["unidade"] is None:
            erros.append(f"fato linha {ln}: `unidade` vazia")
        if r["consultor"] is None:
            erros.append(f"fato linha {ln}: `consultor` vazio")
        if r["passagens"] is not None and r["refil_diant"] > r["passagens"]:
            erros.append(f"fato linha {ln}: refil_diant ({r['refil_diant']}) maior que "
                         f"passagens ({r['passagens']}) — {r['consultor']}")

    # ---- fato: chave órfã (o que a FOREIGN KEY garantia antes)
    orfas = sorted(set(f["unidade"].dropna()) - set(u["unidade"].dropna()))
    if orfas:
        erros.append(f"Unidade no `fato` que não existe em dim_unidade: {orfas}")
    orfas = sorted(set(f["consultor"].dropna()) - set(dc["consultor"].dropna()))
    if orfas:
        erros.append(f"Consultor no `fato` que não existe em dim_consultor: {orfas}")

    # ---- fato: snapshot repetido (o que a UNIQUE garantia antes)
    val = f[f["mes"].notna()]
    dup = val[val.duplicated(["mes", "data_corte", "unidade", "consultor"], keep=False)]
    for _, r in dup.iterrows():
        erros.append(f"fato linha {int(r['_linha'])}: snapshot repetido — "
                     f"{r['consultor']} / {r['unidade']} / "
                     f"{r['mes'].strftime('%m/%Y')} / corte {r['data_corte']}")

    # ---- fato: dois fechamentos no mesmo mês = faturamento contado em dobro
    fe = val[val["fechado"]]
    dupf = fe[fe.duplicated(["mes", "unidade", "consultor"], keep=False)]
    for _, r in dupf.iterrows():
        erros.append(f'fato linha {int(r["_linha"])}: mais de um snapshot com '
                     f'fechado="Sim" — {r["consultor"]} / {r["unidade"]} / '
                     f'{r["mes"].strftime("%m/%Y")}')

    # ---- fato: acumulado tem que ser MONOTÔNICO
    #      Acumulado só sobe. Se caiu, quase sempre é o delta da semana digitado
    #      no lugar do acumulado — o erro mais provável nesse novo fluxo.
    for (mes, uni, cons), g in val.groupby(["mes", "unidade", "consultor"]):
        g = g.sort_values("data_corte")
        ant = None
        for _, r in g.iterrows():
            if ant is not None:
                for col, rot in (("refil_diant", "refil dianteiro"),
                                 ("refil_tras", "refil traseiro"),
                                 ("passagens", "passagens")):
                    a, b = ant[col], r[col]
                    if a is None or b is None or pd.isna(a) or pd.isna(b):
                        continue
                    if b < a:
                        erros.append(
                            f"fato linha {int(r['_linha'])}: acumulado de {rot} CAIU "
                            f"({a} em {ant['data_corte']} -> {b} em {r['data_corte']}) "
                            f"— {cons} / {uni} / {mes.strftime('%m/%Y')}. "
                            f"Acumulado só pode subir: conferir se não foi digitado "
                            f"o valor da semana em vez do acumulado do mês.")
            ant = r

    # ---- vigência cobrindo cada lançamento
    for (mes, uni), _ in val.groupby(["mes", "unidade"]):
        if vigente(dg, uni, mes, "unidade") is None:
            erros.append(f"Sem gerente vigente para '{uni}' em {mes.strftime('%m/%Y')} "
                         f"— acrescente a linha em dim_gerente com a vigência certa.")
    marca_de = u.set_index("unidade")["marca"].to_dict()
    for (mes, uni), _ in val.groupby(["mes", "unidade"]):
        m = marca_de.get(uni)
        if m and vigente(dp, m, mes, "marca") is None:
            erros.append(f"Sem preço vigente da marca '{m}' em {mes.strftime('%m/%Y')} "
                         f"— acrescente a linha em dim_preco.")

    # ---- avisos (não bloqueiam)
    for mes, g in val.groupby("mes"):
        if mes >= mes_corrente:
            continue
        if not g["fechado"].any():
            avisos.append(f"{mes.strftime('%m/%Y')} é mês passado e não tem nenhum "
                          f'snapshot marcado fechado="Sim". O dash vai usar o último '
                          f"parcial ({g['data_corte'].max()}) como se fosse o fechamento.")
    for _, r in fe.iterrows():
        ult = dt.date(r["mes"].year, r["mes"].month,
                      monthrange(r["mes"].year, r["mes"].month)[1])
        if r["data_corte"] != ult:
            avisos.append(f"fato linha {int(r['_linha'])}: marcado como fechamento mas "
                          f"data_corte é {r['data_corte']}, não {ult} (fim do mês).")
    sem_lanc = sorted(set(dc[dc["ativo"]]["consultor"]) - set(val["consultor"]))
    if sem_lanc:
        avisos.append(f"{len(sem_lanc)} consultor(es) ativo(s) sem nenhum lançamento: "
                      f"{sem_lanc[:8]}{' ...' if len(sem_lanc) > 8 else ''}")
    n_nulas = int(val["passagens"].isna().sum())
    if n_nulas:
        avisos.append(f"{n_nulas} linha(s) sem passagens informadas — ficam fora do "
                      f"cálculo de aproveitamento (é o comportamento correto).")
    return erros, avisos


# --------------------------------------------------------------------------
# Preparo das linhas finais (preço e gerente já congelados)
# --------------------------------------------------------------------------
def montar_linhas(dados):
    f, u = dados["fato"], dados["dim_unidade"]
    dg, dp = dados["dim_gerente"], dados["dim_preco"]
    marca_de = u.set_index("unidade")["marca"].to_dict()
    linhas = []
    for _, r in f[f["mes"].notna()].iterrows():
        mes = r["mes"]
        g = vigente(dg, r["unidade"], mes, "unidade")
        p = vigente(dp, marca_de[r["unidade"]], mes, "marca")
        linhas.append({
            "consultor": r["consultor"], "unidade": r["unidade"],
            "mes": mes, "data_corte": r["data_corte"],
            "fechado": 1 if r["fechado"] else 0,
            "passagens": None if pd.isna(r["passagens"]) else int(r["passagens"]),
            "refil_diant": int(r["refil_diant"]), "refil_tras": int(r["refil_tras"]),
            "preco_diant": float(p["preco_diant"]), "preco_tras": float(p["preco_tras"]),
            "gerente": g["gerente"],
        })
    return linhas


# --------------------------------------------------------------------------
# Gravação — full refresh numa transação só
# --------------------------------------------------------------------------
def gravar(cfg, dados, linhas):
    eng = create_engine(_url(cfg), pool_pre_ping=True,
                        connect_args={"connect_timeout": 30})
    u, dc, dg, dp = (dados["dim_unidade"], dados["dim_consultor"],
                     dados["dim_gerente"], dados["dim_preco"])
    with eng.begin() as cx:
        # 1) fato primeiro: libera as dimensões para serem podadas depois
        cx.execute(text("DELETE FROM lancamentos"))

        # 2) preços: histórico inteiro do Excel
        cx.execute(text("DELETE FROM precos_marca"))
        cx.execute(text("INSERT INTO precos_marca "
                        "(marca, vigencia_inicio, preco_diant, preco_tras) "
                        "VALUES (:marca, :vig, :pd, :pt)"),
                   [{"marca": r["marca"], "vig": r["vigencia_inicio"],
                     "pd": float(r["preco_diant"]), "pt": float(r["preco_tras"])}
                    for _, r in dp.iterrows()])

        # 3) unidades: upsert por nome, para o id de cada unidade não trocar a
        #    cada carga (id estável evita surpresa em link/cache do app)
        gerente_atual = {}
        for uni in u["unidade"]:
            linhas_g = dg[dg["unidade"] == uni].sort_values("vigencia_inicio")
            gerente_atual[uni] = (linhas_g.iloc[-1]["gerente"]
                                  if len(linhas_g) else None)
        cx.execute(text("""
            INSERT INTO unidades (marca, loja, nome_exibicao, gerente, ativo)
            VALUES (:marca, :loja, :nome, :ger, :ativo)
            ON DUPLICATE KEY UPDATE marca=VALUES(marca), loja=VALUES(loja),
                gerente=VALUES(gerente), ativo=VALUES(ativo)
        """), [{"marca": r["marca"], "loja": r["loja"], "nome": r["unidade"],
                "ger": gerente_atual.get(r["unidade"]),
                "ativo": 1 if r["ativo"] else 0} for _, r in u.iterrows()])
        id_uni = {n: i for i, n in cx.execute(
            text("SELECT id, nome_exibicao FROM unidades")).all()}

        # 4) consultores: upsert por nome
        cx.execute(text("""
            INSERT INTO consultores (nome, unidade_atual_id, ativo)
            VALUES (:nome, :uid, :ativo)
            ON DUPLICATE KEY UPDATE unidade_atual_id=VALUES(unidade_atual_id),
                ativo=VALUES(ativo)
        """), [{"nome": r["consultor"],
                "uid": id_uni.get(r["unidade_atual"]),
                "ativo": 1 if r["ativo"] else 0} for _, r in dc.iterrows()])
        id_cons = {n: i for i, n in cx.execute(
            text("SELECT id, nome FROM consultores")).all()}

        # 5) poda: quem saiu do Excel sai do banco (o Excel é a fonte da verdade)
        nomes_c = list(dc["consultor"])
        nomes_u = list(u["unidade"])
        cx.execute(text("DELETE FROM consultores WHERE nome NOT IN :n"),
                   {"n": tuple(nomes_c) if nomes_c else ("",)})
        cx.execute(text("DELETE FROM unidades WHERE nome_exibicao NOT IN :n"),
                   {"n": tuple(nomes_u) if nomes_u else ("",)})

        # 6) fato
        cx.execute(text("""
            INSERT INTO lancamentos
                (consultor_id, unidade_id, mes, data_corte, fechado,
                 passagens, refil_diant, refil_tras, preco_diant, preco_tras, gerente)
            VALUES (:cid, :uid, :mes, :corte, :fechado,
                    :passagens, :rd, :rt, :pd, :pt, :ger)
        """), [{"cid": id_cons[l["consultor"]], "uid": id_uni[l["unidade"]],
                "mes": l["mes"], "corte": l["data_corte"], "fechado": l["fechado"],
                "passagens": l["passagens"], "rd": l["refil_diant"],
                "rt": l["refil_tras"], "pd": l["preco_diant"],
                "pt": l["preco_tras"], "ger": l["gerente"]} for l in linhas])
    return eng


def conferir(eng, linhas):
    """Confere o que ficou no banco contra o que saiu da planilha. Se a view
    devolver total diferente do esperado, a carga não pode ser considerada boa."""
    esperado_fech = {}
    for l in linhas:
        k = (l["consultor"], l["unidade"], l["mes"])
        atual = esperado_fech.get(k)
        if atual is None or (l["fechado"], l["data_corte"]) > (atual["fechado"], atual["data_corte"]):
            esperado_fech[k] = l
    esp_rd = sum(l["refil_diant"] for l in esperado_fech.values())
    esp_rt = sum(l["refil_tras"] for l in esperado_fech.values())
    esp_tot = round(sum(l["refil_diant"] * l["preco_diant"]
                        + l["refil_tras"] * l["preco_tras"]
                        for l in esperado_fech.values()), 2)
    with eng.connect() as cx:
        n_snap = cx.execute(text("SELECT COUNT(*) FROM lancamentos")).scalar()
        n_view = cx.execute(text("SELECT COUNT(*) FROM vw_base_tidy")).scalar()
        rd = cx.execute(text("SELECT COALESCE(SUM(refil_diant),0) FROM vw_base_tidy")).scalar()
        rt = cx.execute(text("SELECT COALESCE(SUM(refil_tras),0) FROM vw_base_tidy")).scalar()
        tot = cx.execute(text("SELECT COALESCE(ROUND(SUM(total_geral),2),0) FROM vw_base_tidy")).scalar()
        reg = cx.execute(text("SELECT COUNT(*) FROM vw_base_snapshots WHERE regressao=1")).scalar()
    ok = (int(rd) == esp_rd and int(rt) == esp_rt
          and abs(float(tot) - esp_tot) < 0.05
          and int(n_view) == len(esperado_fech))
    print(f"    snapshots gravados : {n_snap}")
    print(f"    linhas na view     : {n_view}   (esperado {len(esperado_fech)})")
    print(f"    refil dianteiro    : {int(rd)}   (esperado {esp_rd})")
    print(f"    refil traseiro     : {int(rt)}   (esperado {esp_rt})")
    print(f"    faturamento        : {_brl(float(tot))}   (esperado {_brl(esp_tot)})")
    print(f"    regressões de acumulado na view: {reg}")
    print(f"    conferência: {'OK' if ok else 'DIVERGIU'}")
    return ok


def _brl(v):
    return ("R$ {:,.2f}".format(v)).replace(",", "X").replace(".", ",").replace("X", ".")


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Carrega BASE DAHRUJ.xlsx no MySQL (full refresh, validado).")
    ap.add_argument("excel", nargs="?", default=str(EXCEL_PADRAO))
    ap.add_argument("--destino", choices=["local", "online", "env"], default=None)
    ap.add_argument("--so-validar", action="store_true",
                    help="valida a planilha e sai sem gravar nada")
    args = ap.parse_args()

    print(f"Planilha: {args.excel}")
    dados = normalizar(ler_excel(args.excel))
    erros, avisos = validar(dados)

    if avisos:
        print(f"\nAVISOS ({len(avisos)}) — não bloqueiam a carga:")
        for a in avisos:
            print(f"  ! {a}")
    if erros:
        print(f"\nERROS ({len(erros)}) — NADA foi gravado:")
        for e in erros[:60]:
            print(f"  x {e}")
        if len(erros) > 60:
            print(f"  ... e mais {len(erros) - 60}")
        sys.exit(1)
    print("\nValidação: planilha limpa.")

    linhas = montar_linhas(dados)
    print(f"Linhas prontas: {len(linhas)} snapshots | "
          f"{len({l['mes'] for l in linhas})} meses | "
          f"{len({l['unidade'] for l in linhas})} unidades | "
          f"{len({l['consultor'] for l in linhas})} consultores")

    if args.so_validar:
        print("\n--so-validar: saindo sem gravar.")
        return

    falhou = False
    for rotulo, cfg in destinos(args.destino):
        print(f"\n>> {rotulo} ({cfg.get('host')}:{cfg.get('port')}/{cfg.get('database')})")
        try:
            eng = gravar(cfg, dados, linhas)
            if not conferir(eng, linhas):
                falhou = True
        except Exception as e:
            falhou = True
            print(f"    FALHOU: {type(e).__name__}: {str(e)[:300]}")
    if falhou:
        sys.exit(2)
    print("\nPronto. O dash publicado já está lendo o dado novo.")


if __name__ == "__main__":
    main()
