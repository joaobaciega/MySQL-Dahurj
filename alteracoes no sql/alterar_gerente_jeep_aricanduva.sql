-- =============================================================================
--  Alteração: gerente da unidade Jeep Aricanduva  (Larissa -> Diego)
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  CONTEXTO
--    O gerente fica gravado em `unidades.gerente` (uma coluna por unidade), e a
--    view vw_base_tidy só lê essa coluna. Então basta 1 UPDATE: nenhum
--    lançamento, consultor ou vínculo é afetado.
--    Obs.: "Diego" também é o gerente da Nissan Braz Leme — são registros
--    distintos (chave marca+loja), o filtro abaixo garante que só a Jeep
--    Aricanduva muda.
--
--  O QUE FAZ (idempotente — pode rodar mais de uma vez sem efeito colateral):
--    1) Troca o gerente da unidade (marca='Jeep', loja='Aricanduva') para Diego.
--
--  COMO RODAR
--    Cole/execute TUDO de uma vez no console MySQL online (o mesmo lugar onde o
--    schema.sql foi aplicado). Depois recarregue o app do Streamlit.
-- =============================================================================

USE dashboard_dahruj;

-- Charset da sessão (mantém o padrão dos outros scripts; nomes com acento).
SET NAMES utf8mb4;

-- Efetiva a gravação mesmo em consoles com autocommit desligado (senão o UPDATE
-- é descartado ao fim da sessão). Há um COMMIT explícito no final também.
SET autocommit = 1;

-- -----------------------------------------------------------------------------
-- 1) Troca do gerente. Filtro por marca+loja (chave única da unidade).
-- -----------------------------------------------------------------------------
UPDATE unidades
   SET gerente = 'Diego'
 WHERE marca = 'Jeep'
   AND loja  = 'Aricanduva';

COMMIT;

-- -----------------------------------------------------------------------------
-- CONFERÊNCIA (rode depois; não altera nada).
--   Esperado: Jeep Aricanduva -> Diego  |  Fiat Aricanduva segue José Elias.
-- -----------------------------------------------------------------------------
-- SELECT id, marca, loja, nome_exibicao, gerente
-- FROM unidades
-- WHERE loja = 'Aricanduva'
-- ORDER BY marca;
