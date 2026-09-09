-- =============================================================================
--  Cadastro: tabelas da aba "Verbas" (vendas por produto + controle de pagamento)
--  Banco: dashboard_dahruj  (MySQL 8.0+ / Aiven)
--
--  CONTEXTO
--    A aba Verbas do dashboard NÃO usa `lancamentos` nem a view `vw_base_tidy`.
--    Ela vive sobre a planilha "Base de dados para Dash Board.xlsx", que é o
--    sell-in (pedidos faturados para as concessionárias, linha a linha por
--    produto) e traz as três verbas geradas por venda: Consultor, Gerente e
--    Reserva de Marketing.
--
--    Por isso as duas tabelas abaixo são ILHAS: sem FK para `unidades` ou
--    `consultores`, sem trigger, sem alterar nada do que já existe. Aplicar
--    este script não muda um único número do Dashboard atual.
--
--  QUEM ESCREVE AQUI
--    `importar_verbas.py`, rodado toda sexta depois de atualizar o Excel.
--    Ele apaga e regrava `vendas_verbas` inteira dentro de UMA transação — o
--    Excel é a fonte da verdade, então não existe merge, só substituição.
--
--  IDEMPOTENTE: CREATE TABLE IF NOT EXISTS. Rodar de novo não apaga dado nem
--  recria tabela existente.
--
--  COMO RODAR (MySQL Workbench)
--    "Execute ALL" — o raio simples (Ctrl+Shift+Enter). Depois rode
--    `python importar_verbas.py` para popular.
-- =============================================================================

USE dashboard_dahruj;

SET NAMES utf8mb4;
SET autocommit = 1;

-- -----------------------------------------------------------------------------
-- 1) vendas_verbas  (TABELA-FATO da aba Verbas)
--    Uma linha por linha da aba `Total` do Excel: um produto dentro de um pedido.
--    O mesmo `pedido` aparece em várias linhas quando o cliente levou mais de um
--    produto — por isso a PK é sintética e a contagem de pedidos no dashboard é
--    COUNT(DISTINCT pedido), nunca COUNT(*).
--
--    Os pares verba/total vêm prontos da planilha (as fórmulas do Excel já
--    calcularam): guardamos os dois para conferência, mas o dashboard soma
--    sempre as colunas `total_*`.
--
--    tipo_refil: 'diant' (produto vendido em Par) ou 'tras' (Unitário). Vem da
--    aba auxiliar `Verbas` do Excel, resolvido pelo código do produto.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vendas_verbas (
  id               INT           NOT NULL AUTO_INCREMENT,
  data             DATE          NOT NULL,
  pedido           VARCHAR(30)   NOT NULL,
  cnpj             VARCHAR(24)   NULL,
  cliente          VARCHAR(180)  NULL,
  codigo           VARCHAR(24)   NULL,
  produto          VARCHAR(180)  NULL,
  tipo_refil       ENUM('diant', 'tras') NULL,
  preco_unit       DECIMAL(10,2) NULL,
  qtde             INT           NOT NULL DEFAULT 0,
  total_item       DECIMAL(12,2) NOT NULL DEFAULT 0,
  verba_consultor  DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_consultor  DECIMAL(12,2) NOT NULL DEFAULT 0,
  verba_gerente    DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_gerente    DECIMAL(12,2) NOT NULL DEFAULT 0,
  verba_reserva    DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_reserva    DECIMAL(12,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY idx_vv_data   (data),
  KEY idx_vv_pedido (pedido)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- 2) verbas_pagamentos  (CONTROLE DE PAGAMENTO POR MÊS)
--    Diz, para cada mês, se a verba de Consultor e a de Gerente já foram pagas.
--    É isto que separa "verba gerada" de "saldo de verba" no dashboard.
--
--    `mes` é sempre o 1º dia do mês (mesma convenção de `lancamentos.mes`).
--
--    Marketing NÃO tem coluna: a reserva de marketing nunca é paga a ninguém,
--    então entra inteira no saldo, em todo mês.
--
--    Janeiro/2026 fica 0/0 de propósito — não se pagou verba de consultor nem de
--    gerente daquelas vendas, tudo virou marketing. Logo o mês inteiro é saldo.
--
--    Quem escreve: `importar_verbas.py`, a partir da aba `Pagamentos` do Excel.
--    Para fechar o pagamento de um mês basta marcar "Sim" lá e reimportar — sem
--    tocar em SQL nem em código.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS verbas_pagamentos (
  mes             DATE      NOT NULL,
  consultor_pago  TINYINT(1) NOT NULL DEFAULT 0,
  gerente_pago    TINYINT(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (mes)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Conferência
-- -----------------------------------------------------------------------------
SELECT 'vendas_verbas'     AS tabela, COUNT(*) AS linhas FROM vendas_verbas
UNION ALL
SELECT 'verbas_pagamentos' AS tabela, COUNT(*) AS linhas FROM verbas_pagamentos;
