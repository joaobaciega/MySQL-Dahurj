# Dashboard Dahruj — Ranking Refis para Palhetas (MVP)

App em Streamlit + MySQL:
- **Dashboard**: acompanhamento trimestral móvel (últimos 3 meses) por consultor,
  unidade e marca, lendo direto do banco.
- **💰 Verbas**: verba gerada, verba já paga e **saldo** (consultor / gerente /
  marketing), com tabela mês a mês e gráfico. Base própria — ver "Aba Verbas".
- **Relatório Por Gerente** e **Relatório Por Consultor**: rankings do mês.
- **Lançamento** (acesso restrito): o gestor informa Passagens e Refis por consultor;
  o faturamento é calculado automaticamente e gravado no banco. Ao salvar, o
  dashboard atualiza.
- **🗂️ Histórico** (acesso restrito, mesmo cadeado): a trilha de **todos** os
  lançamentos já gravados, inclusive os que foram sobrescritos, com o número do
  lançamento dentro do mês, a diferença para o anterior (a venda da semana) e
  exportação em Excel. Ver "Histórico de lançamentos".

## Arquivos

| Arquivo          | Função                                                        |
|------------------|---------------------------------------------------------------|
| `schema.sql`     | Cria o banco `dashboard_dahruj`, as tabelas e a view.         |
| `seed.py`        | Carga inicial dos dados a partir do Excel (formato tidy).     |
| `importar_verbas.py` | Carga semanal da aba Verbas a partir da planilha de vendas. |
| `db.py`          | Camada de dados: conexão e funções de leitura/gravação.       |
| `app.py`         | App integrado (Dashboard + Verbas + Relatórios + Lançamento). |
| `aplicar_migracao_historico.py` | Cria a tabela/view do histórico nos bancos.    |
| `requirements.txt`| Dependências Python.                                          |
| `.streamlit/secrets.toml` | Credenciais do MySQL (criar manualmente).            |

## Instalação (uma vez)

1. **MySQL 8.0+** instalado e rodando. Aplique o esquema:
   ```
   mysql -u root -p < schema.sql
   ```
2. **Dependências**:
   ```
   pip install -r requirements.txt
   ```
3. **Conexão**: crie `.streamlit/secrets.toml` na pasta do projeto:
   ```toml
   [mysql]
   host = "127.0.0.1"
   port = 3306
   user = "root"
   password = "suasenha"
   database = "dashboard_dahruj"
   ```
4. **Carga inicial** (com o Excel tidy na pasta):
   ```
   python seed.py
   ```

## Rodar o app

```
streamlit run app.py
```
Abre em `http://localhost:8501`. O menu lateral alterna entre **Dashboard** e os
dois relatórios.

## Acesso ao Lançamento

A aba **Lançamento** não aparece no menu. Para abrir, clique no **cadeado 🔒** no
fim da barra lateral e informe a senha; a aba passa a aparecer no menu.

- A senha está em `SENHA_LANCAMENTO`, no topo do `app.py`. Para não deixá-la no
  repositório, basta acrescentar ao `.streamlit/secrets.toml` (que é gitignored) —
  o valor do secrets tem prioridade sobre a constante:
  ```toml
  [acesso]
  senha_lancamento = "outra-senha"
  ```
- Volta a trancar: clicando no 🔓, após **30 min sem uso** ou ao recarregar a
  página (F5 abre uma sessão nova). Cada aba do navegador é uma sessão à parte.
- Após 3 senhas erradas, aguarda 1 minuto antes de aceitar nova tentativa.

## Como funciona

- A view `vw_base_tidy` recalcula aproveitamento e faturamento (quantidade ×
  preço da marca) a partir da tabela `lancamentos`. O dashboard lê dessa view.
- Salvar um lançamento faz *upsert* (chave consultor + mês + unidade): uma linha
  por consultor/mês/unidade, sem duplicar. Após salvar, o cache é limpo e o
  dashboard reflete a mudança.
- O mesmo save acrescenta um registro em `lancamentos_historico` — o upsert
  continua sobrescrevendo o mês, mas o valor anterior não se perde mais. Ver
  "Histórico de lançamentos".
- A janela de 3 meses é automática: quando entra um mês novo, o mais antigo sai.

## Histórico de lançamentos

O dashboard mostra, de cada mês, o **acumulado mais recente** — é o certo, mas
apagava o rastro: depois do 2º lançamento não dava para saber quanto tinha sido
vendido em cada semana. A tabela `lancamentos_historico` resolve isso sem mudar
nada no dashboard.

- É **append-only**: cada "Salvar lançamento" e cada exclusão vira uma linha,
  nunca atualizada e nunca apagada pelo app. Guarda o estado do mês *depois* do
  evento (na exclusão, zeros) e um snapshot do nome do consultor, da unidade e da
  marca, para a exportação continuar legível se o cadastro mudar depois.
- A view `vw_lancamentos_historico` calcula na leitura o **nº do lançamento no
  mês** (por consultor e unidade) e as colunas *no período* — a diferença para o
  lançamento anterior, ou seja, a venda daquela semana. A soma das diferenças de
  um mês sempre bate com o acumulado que o dashboard mostra.
- A página **🗂️ Histórico** filtra por mês/unidade/consultor e exporta um Excel
  com duas abas: `Histórico` (evento a evento) e `Semanal` (consultor × nº do
  lançamento, com o faturamento de cada período).

### Instalação (uma vez, em cada banco)

```
python aplicar_migracao_historico.py                  # local + online
python aplicar_migracao_historico.py --destino online # só o online
python aplicar_migracao_historico.py --conferir       # não grava, só confere
```

O script roda `alteracoes no sql/add_historico_lancamentos.sql`, que cria a
tabela e a view e copia os lançamentos que já existem como o nº 1 de cada mês.
É idempotente: rodar de novo não duplica nada. Existe como script (em vez de
colar o SQL no console) porque no Aiven o autocommit vem desligado e a alteração
feita na mão fica pendente — aqui o COMMIT é explícito.

> **Cargas em massa não alimentam o histórico.** `seed.py` e `carregar_base.py`
> escrevem direto em `lancamentos`, sem passar pelo `db.py`. Só a tela de
> Lançamento gera eventos — que é o fluxo do dia a dia. Se um dia a carga em
> massa virar rotina, ela precisa gravar o evento também.

## Aba Verbas

Esta aba **não** usa a view `vw_base_tidy`. Ela vive sobre a planilha
`Base de dados para Dash Board.xlsx` (sell-in: pedidos faturados para as
concessionárias, linha a linha por produto), em duas tabelas próprias
(`vendas_verbas` e `verbas_pagamentos`) que não têm FK com o resto do banco.

São bases diferentes de propósito: o Dashboard mede o sell-out por consultor
(passagens → refis); a aba Verbas mede a verba gerada por venda. Por isso os
cards dela saem todos da mesma base. **Passagens e Aproveitamento não aparecem
lá** — a planilha de vendas não tem passagens, e não há como derivá-las.

### Instalação (uma vez, em cada banco)

```
mysql -u root -p dashboard_dahruj < "alteracoes no sql/add_verbas.sql"
mysql -u root -p dashboard_dahruj < "alteracoes no sql/verbas_pagamentos_inicial.sql"
```

O segundo grava o estado inicial dos pagamentos (Fev–Jul/2026 pagos). Depois
disso quem manda é a planilha.

### Rotina semanal (sexta-feira)

1. Atualize a planilha: novas vendas entram no topo da aba `Total`; as fórmulas
   recalculam as três verbas sozinhas.
2. Rode:
   ```
   python importar_verbas.py
   ```
3. Confira o relatório impresso — ele compara o que foi gravado no banco com o
   que estava no Excel (linhas, faturamento e as três verbas). Tudo `OK` = pronto.

O script **apaga e regrava** `vendas_verbas` inteira dentro de uma transação: a
planilha é a fonte da verdade, então rodar duas vezes dá o mesmo resultado. O
dashboard reflete a mudança em até 60s (TTL do cache de leitura).

### Fechar o pagamento de um mês

Na aba **`Pagamentos`** da planilha (colunas `Mês` · `Consultor Pago` ·
`Gerente Pago`), marque `Sim` no mês que foi pago e rode `importar_verbas.py`.
Aquele mês sai do saldo. Sem tocar em SQL nem em código.

- Marketing não tem coluna: a reserva nunca é paga a ninguém, é sempre saldo.
- Jan/2026 fica `Não`/`Não` — não se pagou verba daquelas vendas, tudo virou
  marketing, então o mês inteiro é saldo.
- Se a aba `Pagamentos` não existir, o script preserva o que já está no banco e
  avisa — nunca zera em silêncio.

### Atualizar também o banco online

Acrescente uma seção `[mysql_online]` ao `.streamlit/secrets.toml` local (o
arquivo é gitignored) com as credenciais do Streamlit Cloud. Sem `--destino`, o
script grava em todos os bancos configurados numa rodada só:

```
python importar_verbas.py                     # local + online
python importar_verbas.py --destino online    # só o online
```

## Trocar dados dummy pelos oficiais

Para começar limpo com os dados reais: rode `schema.sql` de novo (zera as
tabelas) e depois `python seed.py` apontando para o Excel oficial. O app não
precisa de nenhuma alteração.
