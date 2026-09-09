-- =============================================================================
--  Migração: UNIDADE POR LANÇAMENTO (lancamentos.unidade_id)
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  CONTEXTO
--    O Rafael Alves de Sa saiu da Nissan Braz Leme NO MEIO de Junho/2026 e foi
--    para a Nissan Ceasa. No modelo antigo a unidade era resolvida pelo MÊS do
--    lançamento (via consultor_unidade), então era impossível o mesmo consultor
--    ter, em Junho, um resultado na Braz Leme E outro na Ceasa.
--
--  O QUE ESTA MIGRAÇÃO FAZ (idempotente — pode rodar mais de uma vez)
--    1) Adiciona lancamentos.unidade_id.
--    2) BACKFILL: preenche unidade_id de cada lançamento com a unidade que a
--       vigência ANTIGA cobria (mesma regra da view antiga) — preserva 100% do
--       histórico como o dashboard já mostra. (Roda ANTES de mexer no Rafael.)
--    3) Torna unidade_id NOT NULL (só se o backfill cobriu tudo), troca a UNIQUE
--       para (consultor_id, mes, unidade_id) e cria a FK para unidades.
--    4) Ajusta as vigências do Rafael (só para a TELA de Lançamento): fecha a
--       Braz Leme e abre a Ceasa a partir de 2026-06-01.
--    5) Recria a view resolvendo a unidade por l.unidade_id.
--
--  COMO RODAR
--    Faça backup antes:  mysqldump -u root -p dashboard_dahruj > backup.sql
--    Depois cole/execute TUDO de uma vez no console MySQL (online ou local).
--
--  SUBSTITUI, para este cenário, os scripts antigos baseados em Julho:
--    atualizar_online.sql, fix_rafael_ceasa.sql, migration_transferencia_unidade.sql
-- =============================================================================

USE dashboard_dahruj;

-- -----------------------------------------------------------------------------
-- 1) Adiciona a coluna unidade_id (nullable primeiro). Guardado por
--    information_schema porque o MySQL não tem ADD COLUMN IF NOT EXISTS.
-- -----------------------------------------------------------------------------
SET @tem_col := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND column_name = 'unidade_id'
);
SET @sql := IF(@tem_col = 0,
  'ALTER TABLE lancamentos ADD COLUMN unidade_id INT NULL AFTER consultor_id',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- -----------------------------------------------------------------------------
-- 2) BACKFILL a partir da vigência antiga (mesma regra do JOIN da view antiga).
--    Só toca linhas ainda NULL => rodar de novo é no-op. Como as vigências não
--    se sobrepõem, cada lançamento casa com exatamente uma unidade.
--    IMPORTANTE: roda ANTES do passo 4 (que muda a vigência do Rafael), senão o
--    Junho dele casaria com Braz Leme E Ceasa ao mesmo tempo.
-- -----------------------------------------------------------------------------
UPDATE lancamentos l
JOIN consultor_unidade cu
  ON cu.consultor_id = l.consultor_id
 AND l.mes >= cu.vigencia_inicio
 AND (cu.vigencia_fim IS NULL OR l.mes <= cu.vigencia_fim)
SET l.unidade_id = cu.unidade_id
WHERE l.unidade_id IS NULL;

-- -----------------------------------------------------------------------------
-- 3) Estrutura: NOT NULL (só se o backfill cobriu tudo), UNIQUE e FK.
-- -----------------------------------------------------------------------------
-- 3a) Torna NOT NULL apenas se não sobrou nenhum unidade_id nulo. Se sobrar,
--     mostra um aviso e mantém a coluna nullable (a view esconde linhas nulas,
--     igual ao comportamento antigo de linhas fora de vigência).
SET @nulos := (SELECT COUNT(*) FROM lancamentos WHERE unidade_id IS NULL);
SELECT IF(@nulos = 0,
          'Backfill OK: nenhum unidade_id nulo.',
          CONCAT('ATENCAO: ', @nulos, ' lancamento(s) sem unidade_id (fora de ',
                 'qualquer vigencia). Coluna mantida NULLABLE. Investigue antes.')
       ) AS status_backfill;
SET @col_nn := (
  SELECT is_nullable FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND column_name = 'unidade_id'
);
SET @sql := IF(@nulos = 0 AND @col_nn = 'YES',
  'ALTER TABLE lancamentos MODIFY COLUMN unidade_id INT NOT NULL',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- 3b) Troca a UNIQUE (consultor_id, mes) -> (consultor_id, mes, unidade_id).
--     ATENÇÃO: a unique antiga (consultor_id, mes) é o índice que dá suporte à
--     FK de consultor_id — não dá para derrubá-la primeiro (erro 1553). Então:
--       (1) cria a nova unique com nome temporário (também começa em consultor_id,
--           logo passa a dar suporte à FK);
--       (2) derruba a unique antiga de 2 colunas;
--       (3) renomeia a nova para uq_lancamento.
--     Tudo guardado pelo estado atual, para ser idempotente e recuperar runs
--     parciais.
SET @uq_cols := (
  SELECT GROUP_CONCAT(column_name ORDER BY seq_in_index)
  FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND index_name = 'uq_lancamento'
);
SET @tem_v2 := (
  SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND index_name = 'uq_lancamento_v2'
);
-- (1) cria a nova unique (temp) se a final ainda não estiver correta.
SET @sql := IF(@uq_cols <> 'consultor_id,mes,unidade_id' AND @tem_v2 = 0,
  'ALTER TABLE lancamentos ADD UNIQUE KEY uq_lancamento_v2 (consultor_id, mes, unidade_id)',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;
-- (2) derruba a antiga de 2 colunas (a FK passa a se apoiar na v2).
SET @uq_cols := (
  SELECT GROUP_CONCAT(column_name ORDER BY seq_in_index)
  FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND index_name = 'uq_lancamento'
);
SET @sql := IF(@uq_cols = 'consultor_id,mes',
  'ALTER TABLE lancamentos DROP INDEX uq_lancamento',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;
-- (3) renomeia a v2 para uq_lancamento (se a final ainda não existir).
SET @tem_uq := (
  SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND index_name = 'uq_lancamento'
);
SET @tem_v2 := (
  SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND index_name = 'uq_lancamento_v2'
);
SET @sql := IF(@tem_uq = 0 AND @tem_v2 = 1,
  'ALTER TABLE lancamentos RENAME INDEX uq_lancamento_v2 TO uq_lancamento',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- 3c) Índice de apoio para a FK/joins (idempotente).
SET @tem_idx := (
  SELECT COUNT(*) FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND index_name = 'idx_lancamento_unidade'
);
SET @sql := IF(@tem_idx = 0,
  'ALTER TABLE lancamentos ADD KEY idx_lancamento_unidade (unidade_id)',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- 3d) FK unidade_id -> unidades(id) (só se ainda não existir).
SET @tem_fk := (
  SELECT COUNT(*) FROM information_schema.table_constraints
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND constraint_type = 'FOREIGN KEY'
    AND constraint_name = 'fk_lancamento_unidade'
);
SET @sql := IF(@tem_fk = 0,
  'ALTER TABLE lancamentos ADD CONSTRAINT fk_lancamento_unidade
     FOREIGN KEY (unidade_id) REFERENCES unidades (id)
     ON UPDATE CASCADE ON DELETE RESTRICT',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- -----------------------------------------------------------------------------
-- 4) Vigências do Rafael (só afetam a TELA de Lançamento, não a view).
--    Garante a Ceasa, fecha a Braz Leme e abre a Ceasa a partir de 2026-06-01.
-- -----------------------------------------------------------------------------
INSERT INTO unidades (marca, loja, nome_exibicao, gerente)
SELECT 'Nissan', 'Ceasa', 'Nissan Ceasa', NULL
WHERE NOT EXISTS (SELECT 1 FROM unidades WHERE nome_exibicao = 'Nissan Ceasa');

-- 4a) Fecha a Braz Leme (sai da lista da Braz Leme na tela). O Junho dele na
--     Braz Leme continua no dashboard porque a view lê de lancamentos.unidade_id.
UPDATE consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
SET cu.vigencia_fim = '2026-05-01'
WHERE c.nome = 'Rafael Alves de Sa'
  AND u.nome_exibicao = 'Nissan Braz Leme';

-- 4b) Abre/ajusta a Ceasa para começar em 2026-06-01 e ficar vigente (fim NULL).
UPDATE consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
SET cu.vigencia_inicio = '2026-06-01', cu.vigencia_fim = NULL
WHERE c.nome = 'Rafael Alves de Sa'
  AND u.nome_exibicao = 'Nissan Ceasa';

INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT c.id, u.id, '2026-06-01', NULL
FROM consultores c
JOIN unidades u ON u.nome_exibicao = 'Nissan Ceasa'
WHERE c.nome = 'Rafael Alves de Sa';

-- -----------------------------------------------------------------------------
-- 5) View: unidade resolvida pelo PRÓPRIO lançamento (l.unidade_id).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_base_tidy AS
SELECT
  c.id                                     AS consultor_id,
  c.nome                                   AS consultor,
  u.id                                     AS unidade_id,
  u.nome_exibicao                          AS unidade,
  u.loja                                   AS loja,
  u.marca                                  AS marca,
  u.gerente                                AS gerente,
  l.mes                                    AS mes,
  DATE_FORMAT(l.mes, '%m/%Y')              AS mes_label,
  l.passagens                              AS passagens,
  l.refil_diant                            AS refil_diant,
  l.refil_tras                             AS refil_tras,
  CASE WHEN l.passagens > 0
       THEN ROUND(l.refil_diant / l.passagens, 4)
       ELSE NULL
  END                                      AS aproveitamento,
  ROUND(l.refil_diant * p.preco_diant, 2)  AS total_diant,
  ROUND(l.refil_tras  * p.preco_tras,  2)  AS total_tras,
  ROUND(l.refil_diant * p.preco_diant
      + l.refil_tras  * p.preco_tras,  2)  AS total_geral
FROM lancamentos l
JOIN consultores  c ON c.id    = l.consultor_id
JOIN unidades     u ON u.id    = l.unidade_id
JOIN precos_marca p ON p.marca = u.marca;

-- -----------------------------------------------------------------------------
-- 6) (OPCIONAL) Remover o placeholder de Julho/2026 com zeros, inserido pelos
--    scripts antigos: no novo modelo ele não é mais necessário. Descomente se
--    quiser limpar. NÃO remove se houver vendas reais lançadas em Julho.
-- -----------------------------------------------------------------------------
-- DELETE l FROM lancamentos l
-- JOIN consultores c ON c.id = l.consultor_id
-- JOIN unidades    u ON u.id = l.unidade_id
-- WHERE c.nome = 'Rafael Alves de Sa'
--   AND u.nome_exibicao = 'Nissan Ceasa'
--   AND l.mes = '2026-07-01'
--   AND l.passagens IS NULL AND l.refil_diant = 0 AND l.refil_tras = 0;

-- -----------------------------------------------------------------------------
-- CONFERÊNCIA (rode depois; após lançar o Junho da Ceasa deve haver DUAS linhas
-- de 06/2026 para o Rafael — uma Braz Leme, uma Ceasa):
-- -----------------------------------------------------------------------------
-- SELECT consultor, unidade, mes_label, passagens, total_geral
-- FROM vw_base_tidy WHERE consultor = 'Rafael Alves de Sa' ORDER BY mes, unidade;
