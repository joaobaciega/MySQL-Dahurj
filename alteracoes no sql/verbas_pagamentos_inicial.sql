-- =============================================================================
--  Carga inicial de `verbas_pagamentos` — situação em Agosto/2026
--  Banco: dashboard_dahruj  (MySQL 8.0+ / Aiven)
--
--  PRA QUE SERVE
--    A partir da 2ª importação quem manda é a aba `Pagamentos` da planilha:
--    `importar_verbas.py` regrava esta tabela inteira com o que estiver lá.
--    Este arquivo existe só para o estado inicial — enquanto a aba não foi
--    criada, o importador PRESERVA a tabela (não zera em silêncio), então sem
--    esta carga a aba Verbas mostraria "nada pago" e um saldo de R$ 129.122,50.
--
--    Rode uma vez em cada banco (local e online). Depois pode esquecer: a
--    planilha assume.
--
--  O QUE ESTÁ SENDO DITO AQUI
--    Fev–Jul/2026 : verba de consultor e de gerente já pagas.
--    Jan/2026     : nada pago a consultor nem a gerente — aquelas vendas viraram
--                   todas marketing, então o mês inteiro é saldo.
--    Ago/2026     : ainda em aberto. Quando o pagamento sair (previsto para
--                   setembro), marque "Sim" na aba `Pagamentos` do Excel e rode
--                   `python importar_verbas.py` — sem tocar em SQL.
--
--    Marketing não aparece: a reserva nunca é paga a ninguém, é sempre saldo.
--
--  CONFERÊNCIA ESPERADA depois de rodar (com a base de 163 vendas):
--    verba gerada 129.122,50 · paga 83.250,00 · SALDO 45.872,50
--
--  IDEMPOTENTE: UPSERT na chave `mes`. Rodar de novo não duplica nem altera.
--
--  COMO RODAR (MySQL Workbench): "Execute ALL" (Ctrl+Shift+Enter).
-- =============================================================================

USE dashboard_dahruj;

SET NAMES utf8mb4;
SET autocommit = 1;

INSERT INTO verbas_pagamentos (mes, consultor_pago, gerente_pago) VALUES
  ('2026-01-01', 0, 0),
  ('2026-02-01', 1, 1),
  ('2026-03-01', 1, 1),
  ('2026-04-01', 1, 1),
  ('2026-05-01', 1, 1),
  ('2026-06-01', 1, 1),
  ('2026-07-01', 1, 1),
  ('2026-08-01', 0, 0)
ON DUPLICATE KEY UPDATE
  consultor_pago = VALUES(consultor_pago),
  gerente_pago   = VALUES(gerente_pago);

-- Conferência: deve devolver gerada 129.122,50 / paga 83.250,00 / saldo 45.872,50
SELECT
  ROUND(SUM(v.total_consultor + v.total_gerente + v.total_reserva), 2) AS gerada,
  ROUND(SUM(IF(p.consultor_pago = 1, v.total_consultor, 0))
      + SUM(IF(p.gerente_pago   = 1, v.total_gerente,   0)), 2)        AS paga,
  ROUND(SUM(v.total_consultor + v.total_gerente + v.total_reserva)
      - SUM(IF(p.consultor_pago = 1, v.total_consultor, 0))
      - SUM(IF(p.gerente_pago   = 1, v.total_gerente,   0)), 2)        AS saldo
FROM vendas_verbas v
LEFT JOIN verbas_pagamentos p
       ON p.mes = DATE_FORMAT(v.data, '%Y-%m-01');
