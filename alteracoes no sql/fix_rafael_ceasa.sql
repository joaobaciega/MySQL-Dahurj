-- =============================================================================
--  Correção: transferência do Rafael Alves de Sa p/ a Nissan Ceasa (Julho/2026)
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  QUANDO USAR ESTE SCRIPT
--    Use quando o banco JÁ FOI migrado (a tabela `consultor_unidade` já existe).
--    Confira antes:
--        SHOW TABLES LIKE 'consultor_unidade';
--      - Retornou a tabela  -> rode ESTE arquivo (fix_rafael_ceasa.sql).
--      - NÃO retornou nada  -> rode o migration_transferencia_unidade.sql (já corrigido),
--                              que cria tudo e já faz a transferência de uma vez.
--
--  POR QUE ESTE SCRIPT EXISTE
--    A migração anterior filtrou por nome = 'Rafael' (nome real:
--    'Rafael Alves de Sa'), então a transferência não pegou. Além disso os dados
--    dele vão só até 05/2026 — para aparecer em Julho na Ceasa é preciso um
--    lançamento placeholder de Julho com zeros (a view só mostra meses que têm
--    lançamento).
--
--  O QUE FAZ (seguro e idempotente — pode rodar mais de uma vez):
--    1) Fecha o vínculo dele na Nissan Braz Leme em Junho/2026.
--    2) Garante que a Nissan Ceasa exista.
--    3) Abre o vínculo na Nissan Ceasa a partir de Julho/2026.
--    4) Insere o lançamento de Julho/2026 com zeros (total geral = 0).
--
--  COMO RODAR
--    Cole e execute no console MySQL (online ou local). Faça um export/backup antes.
--    Se o seu banco tiver outro nome, ajuste o USE abaixo (ou remova, se o console
--    já estiver no banco certo).
-- =============================================================================

USE dashboard_dahruj;

START TRANSACTION;

-- 1) Fecha o vínculo do Rafael na Braz Leme em Junho/2026 (Junho p/ trás fica Braz Leme).
UPDATE consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
SET cu.vigencia_fim = '2026-06-01'
WHERE c.nome = 'Rafael Alves de Sa'
  AND u.nome_exibicao = 'Nissan Braz Leme'
  AND cu.vigencia_fim IS NULL;

-- 2) Garante que a Nissan Ceasa exista (ajuste loja/gerente se necessário).
INSERT INTO unidades (marca, loja, nome_exibicao, gerente)
SELECT 'Nissan', 'Ceasa', 'Nissan Ceasa', NULL
WHERE NOT EXISTS (
  SELECT 1 FROM unidades WHERE nome_exibicao = 'Nissan Ceasa'
);

-- 3) Abre o vínculo na Ceasa a partir de Julho/2026.
--    INSERT IGNORE na chave (consultor_id, unidade_id, vigencia_inicio) => rodar 2x não duplica.
INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT c.id, u.id, '2026-07-01', NULL
FROM consultores c
JOIN unidades u ON u.nome_exibicao = 'Nissan Ceasa'
WHERE c.nome = 'Rafael Alves de Sa';

-- 4) Lançamento placeholder de Julho/2026 com zeros => aparece na Ceasa com total 0.
--    INSERT IGNORE na chave (consultor_id, mes) => se um dia entrarem vendas reais
--    de Julho pelo app, NÃO serão sobrescritas ao rodar isto de novo.
INSERT IGNORE INTO lancamentos (consultor_id, mes, passagens, refil_diant, refil_tras)
SELECT c.id, '2026-07-01', 0, 0, 0
FROM consultores c
WHERE c.nome = 'Rafael Alves de Sa';

COMMIT;

-- -----------------------------------------------------------------------------
-- CONFERÊNCIA (rode depois; deve mostrar Braz Leme em 02–05/2026 e Ceasa em 07/2026)
-- -----------------------------------------------------------------------------
-- SELECT consultor, unidade, mes_label, total_geral
-- FROM vw_base_tidy
-- WHERE consultor = 'Rafael Alves de Sa'
-- ORDER BY mes;
