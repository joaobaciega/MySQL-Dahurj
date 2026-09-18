-- =============================================================================
--  Cadastro: `verbas_marketing_pagos` — pagamentos da verba de MARKETING
--  Banco: dashboard_dahruj  (MySQL 8.0+ / Aiven)
--
--  PRA QUE SERVE
--    Consultor e gerente são pagos por mês inteiro — por isso `verbas_pagamentos`
--    guarda só um SIM/NÃO. Marketing não funciona assim: a reserva se acumula e é
--    gasta em pedaços, em eventos, quando a concessionária decide. O que precisa
--    ser guardado aqui é um VALOR, não um flag.
--
--    Daí uma tabela separada, com uma linha por mês de pagamento e o valor total
--    pago naquele mês. O dashboard desconta esse valor do saldo de marketing.
--
--  QUEM ESCREVE AQUI
--    `importar_verbas.py`, a partir da aba `VERBAS DE MARKETING` da planilha
--    "Base de dados para Dash Board.xlsx" (colunas `Mês do pgto` · `valor`).
--    Cada rodada apaga e regrava a tabela inteira: o Excel é a fonte da verdade.
--    Se a aba não existir, o script preserva o que está aqui e avisa.
--
--    Vários pagamentos no mesmo mês? Basta repetir o mês na planilha em linhas
--    diferentes — o importador soma antes de gravar, por isso a PK é o mês.
--
--  O VALOR PAGO PODE PASSAR A VERBA GERADA NO MÊS, e isso não é erro: a verba de
--  marketing é um caixa acumulado, então um evento caro em maio pode consumir o
--  que sobrou de janeiro a abril. O saldo daquele mês fica negativo na tabela
--  mês a mês e o saldo do ano continua correto.
--
--  IDEMPOTENTE: CREATE TABLE IF NOT EXISTS. Rodar de novo não apaga dado.
--
--  COMO RODAR (MySQL Workbench): "Execute ALL" (Ctrl+Shift+Enter), uma vez em
--  cada banco (local e online). Depois rode `python importar_verbas.py`.
-- =============================================================================

USE dashboard_dahruj;

SET NAMES utf8mb4;
SET autocommit = 1;

CREATE TABLE IF NOT EXISTS verbas_marketing_pagos (
  mes    DATE          NOT NULL,          -- sempre o 1º dia do mês do pagamento
  valor  DECIMAL(12,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (mes)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -----------------------------------------------------------------------------
-- Conferência: saldo de marketing = gerado − pago (ainda sem pagamento, o pago
-- vem zerado e o saldo é igual ao gerado).
-- -----------------------------------------------------------------------------
SELECT
  ROUND((SELECT COALESCE(SUM(total_reserva), 0) FROM vendas_verbas), 2)          AS mkt_gerado,
  ROUND((SELECT COALESCE(SUM(valor), 0) FROM verbas_marketing_pagos), 2)         AS mkt_pago,
  ROUND((SELECT COALESCE(SUM(total_reserva), 0) FROM vendas_verbas)
      - (SELECT COALESCE(SUM(valor), 0) FROM verbas_marketing_pagos), 2)         AS mkt_saldo;
