-- =============================================================================
--  Dashboard Dahruj — ESQUEMA v2  (MySQL 8.0+)
--
--  O QUE MUDOU EM RELAÇÃO AO v1, E POR QUÊ
--
--  1) A FONTE DE VERDADE É O EXCEL.
--     `BASE DAHRUJ.xlsx` é onde se digita. Este banco é só a camada de LEITURA
--     do dash publicado. Quem escreve aqui é `carregar_base.py`, sempre em
--     full refresh — o banco nunca guarda linha que não exista mais no Excel.
--     Consequência prática: você não escreve mais SQL para cadastrar consultor
--     nem para transferir alguém de unidade.
--
--  2) O GRÃO DE `lancamentos` VIROU SNAPSHOT ACUMULADO.
--     As lojas mandam o acumulado do mês toda segunda (dia 7 = 1 a 7, dia 14 =
--     1 a 14...). Então a chave ganhou `data_corte`, e os valores são
--     ACUMULADOS no mês, não o delta da semana.
--     O dash continua mensal: `vw_base_tidy` devolve UM snapshot por
--     consultor/unidade/mês — o de fechamento, ou o mais recente enquanto o mês
--     está aberto. O contrato de colunas da view é IDÊNTICO ao do v1, por isso
--     o app.py não precisa mudar nada na leitura.
--     A semana isolada é DERIVADA em `vw_base_snapshots` (acumulado atual menos
--     o anterior) — nunca digitada. Se a loja corrigir o acumulado, todas as
--     semanas se recalculam sozinhas.
--
--  3) PREÇO E GERENTE FICAM CONGELADOS NA LINHA DO FATO.
--     No v1 a view multiplicava pelo preço VIGENTE da marca e lia o gerente
--     ATUAL da unidade. Resultado: um reajuste de preço reescrevia o
--     faturamento de meses já fechados, e um gerente que trocasse de loja
--     levava o histórico dele junto. Agora `preco_diant`, `preco_tras` e
--     `gerente` são gravados em CADA lançamento, resolvidos por vigência no
--     momento da carga. Mês fechado nunca mais muda de valor.
--
--  4) `consultor_unidade` DEIXOU DE EXISTIR.
--     Ela só servia para popular o dropdown da aba Lançamento, que morreu.
--     A lotação atual virou `consultores.unidade_atual_id` (conveniência de
--     relatório); a unidade que VALE continua sendo a da linha do lançamento.
--
--  As tabelas da aba Verbas (`vendas_verbas`, `verbas_pagamentos`) NÃO entram
--  nos DROPs: são outra base, alimentada por `importar_verbas.py`, e sobrevivem
--  a uma recriação do esquema.
--
--  Como aplicar:  mysql -u root -p < schema_v2.sql
-- =============================================================================

CREATE DATABASE IF NOT EXISTS dashboard_dahruj
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE dashboard_dahruj;

DROP VIEW  IF EXISTS vw_base_snapshots;
DROP VIEW  IF EXISTS vw_base_tidy;
DROP TABLE IF EXISTS lancamentos;
DROP TABLE IF EXISTS consultor_unidade;
DROP TABLE IF EXISTS consultores;
DROP TABLE IF EXISTS unidades;
DROP TABLE IF EXISTS precos_marca;

-- -----------------------------------------------------------------------------
-- 1) precos_marca  — histórico de preço por marca (vem de `dim_preco` no Excel)
--    A PK inclui a vigência: reajuste é LINHA NOVA, não edição da linha antiga.
--    Serve de rastro. O valor que o dash usa é o já congelado no lançamento.
-- -----------------------------------------------------------------------------
CREATE TABLE precos_marca (
  marca            VARCHAR(50)   NOT NULL,
  vigencia_inicio  DATE          NOT NULL,
  preco_diant      DECIMAL(10,2) NOT NULL,
  preco_tras       DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (marca, vigencia_inicio),
  CONSTRAINT chk_preco_nao_negativo CHECK (preco_diant >= 0 AND preco_tras >= 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 2) unidades  (vem de `dim_unidade`)
--    `gerente` aqui é o gerente ATUAL — conveniência de tela. O histórico de
--    quem respondia pela unidade em cada mês está em `lancamentos.gerente`.
-- -----------------------------------------------------------------------------
CREATE TABLE unidades (
  id             INT          NOT NULL AUTO_INCREMENT,
  marca          VARCHAR(50)  NOT NULL,
  loja           VARCHAR(80)  NOT NULL,
  nome_exibicao  VARCHAR(120) NOT NULL,
  gerente        VARCHAR(120) NULL,
  ativo          TINYINT(1)   NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY uq_unidade_nome (nome_exibicao),
  UNIQUE KEY uq_unidade (marca, loja)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 3) consultores  (vem de `dim_consultor`)
--    `unidade_atual_id` é onde a pessoa está HOJE. Não decide nada de
--    histórico: quem manda é a unidade gravada no lançamento. É isso que faz
--    uma transferência não reescrever o passado.
-- -----------------------------------------------------------------------------
CREATE TABLE consultores (
  id                INT          NOT NULL AUTO_INCREMENT,
  nome              VARCHAR(120) NOT NULL,
  unidade_atual_id  INT          NULL,
  ativo             TINYINT(1)   NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY uq_consultor (nome),
  KEY idx_cons_unidade (unidade_atual_id),
  CONSTRAINT fk_cons_unidade_atual
    FOREIGN KEY (unidade_atual_id) REFERENCES unidades (id)
    ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 4) lancamentos  (TABELA-FATO — grão de SNAPSHOT ACUMULADO)
--    Uma linha por (consultor, unidade, mês, data_corte).
--    passagens / refil_diant / refil_tras são ACUMULADOS do dia 1 até
--    `data_corte`. NUNCA o delta do período.
--
--    `fechado` = 1 marca o snapshot oficial do mês fechado. A coluna gerada
--    `mes_fechamento` + índice único garantem NO BANCO que existe no máximo UM
--    fechamento por consultor/unidade/mês — é a trava contra dupla contagem de
--    faturamento, que era o risco número um de sair do banco para a planilha.
--
--    `passagens` NULL = não informado (linha fica fora do aproveitamento).
--    `passagens` 0    = informou zero. São coisas diferentes.
-- -----------------------------------------------------------------------------
CREATE TABLE lancamentos (
  id              INT       NOT NULL AUTO_INCREMENT,
  consultor_id    INT       NOT NULL,
  unidade_id      INT       NOT NULL,
  mes             DATE      NOT NULL,
  data_corte      DATE      NOT NULL,
  fechado         TINYINT(1) NOT NULL DEFAULT 0,
  passagens       INT       NULL,
  refil_diant     INT       NOT NULL DEFAULT 0,
  refil_tras      INT       NOT NULL DEFAULT 0,
  preco_diant     DECIMAL(10,2) NOT NULL,
  preco_tras      DECIMAL(10,2) NOT NULL,
  gerente         VARCHAR(120) NULL,
  mes_fechamento  DATE GENERATED ALWAYS AS (IF(fechado = 1, mes, NULL)) STORED,
  carregado_em    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_snapshot (consultor_id, unidade_id, mes, data_corte),
  UNIQUE KEY uq_fechamento (consultor_id, unidade_id, mes_fechamento),
  KEY idx_lanc_mes (mes),
  KEY idx_lanc_unidade (unidade_id),
  KEY idx_lanc_mes_fechado (mes, fechado),
  CONSTRAINT fk_lanc_consultor
    FOREIGN KEY (consultor_id) REFERENCES consultores (id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_lanc_unidade
    FOREIGN KEY (unidade_id) REFERENCES unidades (id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_lanc_nao_negativo CHECK (
    (passagens IS NULL OR passagens >= 0) AND refil_diant >= 0 AND refil_tras >= 0
  ),
  CONSTRAINT chk_lanc_corte CHECK (data_corte >= mes),
  CONSTRAINT chk_lanc_mes_dia1 CHECK (DAYOFMONTH(mes) = 1)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- VIEW vw_base_tidy  —  CONTRATO IDÊNTICO AO v1
--    Mesmas colunas, mesmos nomes, mesmos tipos. O app.py não muda.
--
--    A diferença é o filtro: de cada (consultor, unidade, mês) sai UM snapshot
--    só — o marcado como fechamento; na falta dele (mês corrente, ainda
--    aberto), o de `data_corte` mais recente. É isso que preserva o
--    comportamento de hoje, em que o mês em curso já aparece parcial no dash.
--
--    `gerente` e os preços vêm da PRÓPRIA linha (congelados na carga), não mais
--    das dimensões — por isso mês fechado não muda de valor retroativamente.
-- -----------------------------------------------------------------------------
CREATE VIEW vw_base_tidy AS
SELECT
  c.id                                       AS consultor_id,
  c.nome                                     AS consultor,
  u.id                                       AS unidade_id,
  u.nome_exibicao                            AS unidade,
  u.loja                                     AS loja,
  u.marca                                    AS marca,
  l.gerente                                  AS gerente,
  l.mes                                      AS mes,
  DATE_FORMAT(l.mes, '%m/%Y')                AS mes_label,
  l.passagens                                AS passagens,
  l.refil_diant                              AS refil_diant,
  l.refil_tras                               AS refil_tras,
  CASE WHEN l.passagens > 0
       THEN ROUND(l.refil_diant / l.passagens, 4) ELSE NULL
  END                                        AS aproveitamento,
  ROUND(l.refil_diant * l.preco_diant, 2)    AS total_diant,
  ROUND(l.refil_tras  * l.preco_tras,  2)    AS total_tras,
  ROUND(l.refil_diant * l.preco_diant
      + l.refil_tras  * l.preco_tras,  2)    AS total_geral
FROM (
  SELECT x.*,
         ROW_NUMBER() OVER (
           PARTITION BY x.consultor_id, x.unidade_id, x.mes
           ORDER BY x.fechado DESC, x.data_corte DESC
         ) AS rn
  FROM lancamentos x
) l
JOIN consultores c ON c.id = l.consultor_id
JOIN unidades    u ON u.id = l.unidade_id
WHERE l.rn = 1;

-- -----------------------------------------------------------------------------
-- VIEW vw_base_snapshots  —  o controle semanal (não entra no dashboard)
--    Devolve TODOS os snapshots e calcula o DELTA de cada período contra o
--    snapshot anterior do mesmo consultor/unidade/mês. O primeiro snapshot do
--    mês tem delta igual ao próprio acumulado (ele parte do dia 1).
--
--    `dias_periodo` permite comparar semana com semana de forma justa: uma
--    "semana" de 5 dias não é comparável com uma de 9 sem normalizar.
--
--    `regressao` = 1 quando o acumulado DIMINUIU em relação ao snapshot
--    anterior. Acumulado só pode subir; se caiu, alguém digitou errado.
--    Esta é a checagem que o v1 não tinha como fazer.
-- -----------------------------------------------------------------------------
CREATE VIEW vw_base_snapshots AS
SELECT
  c.nome                       AS consultor,
  u.nome_exibicao              AS unidade,
  u.marca                      AS marca,
  l.gerente                    AS gerente,
  l.mes                        AS mes,
  DATE_FORMAT(l.mes, '%m/%Y')  AS mes_label,
  l.data_corte                 AS data_corte,
  l.fechado                    AS fechado,
  l.passagens                  AS passagens_acum,
  l.refil_diant                AS refil_diant_acum,
  l.refil_tras                 AS refil_tras_acum,
  l.passagens - COALESCE(LAG(l.passagens) OVER w, 0)     AS passagens_periodo,
  l.refil_diant - COALESCE(LAG(l.refil_diant) OVER w, 0) AS refil_diant_periodo,
  l.refil_tras  - COALESCE(LAG(l.refil_tras)  OVER w, 0) AS refil_tras_periodo,
  DATEDIFF(l.data_corte,
           COALESCE(LAG(l.data_corte) OVER w, DATE_SUB(l.mes, INTERVAL 1 DAY)))
                                                          AS dias_periodo,
  ROUND((l.refil_diant - COALESCE(LAG(l.refil_diant) OVER w, 0)) * l.preco_diant
      + (l.refil_tras  - COALESCE(LAG(l.refil_tras)  OVER w, 0)) * l.preco_tras, 2)
                                                          AS total_periodo,
  CASE WHEN l.refil_diant < COALESCE(LAG(l.refil_diant) OVER w, 0)
         OR l.refil_tras  < COALESCE(LAG(l.refil_tras)  OVER w, 0)
         OR l.passagens   < COALESCE(LAG(l.passagens)   OVER w, 0)
       THEN 1 ELSE 0
  END                                                     AS regressao
FROM lancamentos l
JOIN consultores c ON c.id = l.consultor_id
JOIN unidades    u ON u.id = l.unidade_id
WINDOW w AS (PARTITION BY l.consultor_id, l.unidade_id, l.mes ORDER BY l.data_corte);
