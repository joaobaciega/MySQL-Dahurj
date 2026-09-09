-- =============================================================================
--  ARQUIVO ÚNICO — atualiza o banco ONLINE em uma rodada só.
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  Objetivo: deixar o Rafael Alves de Sa na Nissan Ceasa a partir de Julho/2026
--  (com total geral 0 em Julho), mantendo o histórico na Nissan Braz Leme.
--
--  FUNCIONA NOS DOIS CENÁRIOS, sem você precisar saber em qual está:
--    - Banco AINDA NÃO migrado  -> cria a tabela de vínculo, faz o backfill e
--      transfere o Rafael.
--    - Banco JÁ migrado          -> só transfere o Rafael (as partes já feitas
--      são ignoradas automaticamente).
--  É idempotente: pode rodar 2x sem duplicar nem estragar nada.
--
--  COMO RODAR
--    Cole e execute TUDO de uma vez no console MySQL online. Faça um export/backup
--    antes. Se o banco tiver outro nome, ajuste o USE abaixo.
--
--  ANTES: confirme os nomes exatos (precisam bater):
--    SELECT nome FROM consultores WHERE nome LIKE 'Rafael%';   -- 'Rafael Alves de Sa'
--    SELECT nome_exibicao FROM unidades;                       -- 'Nissan Braz Leme', 'Nissan Ceasa'
-- =============================================================================

USE dashboard_dahruj;

-- -----------------------------------------------------------------------------
-- 1) Garante a tabela de vínculo consultor<->unidade com vigência (idempotente).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS consultor_unidade (
  id               INT  NOT NULL AUTO_INCREMENT,
  consultor_id     INT  NOT NULL,
  unidade_id       INT  NOT NULL,
  vigencia_inicio  DATE NOT NULL,
  vigencia_fim     DATE NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_cu (consultor_id, unidade_id, vigencia_inicio),
  KEY idx_cu_consultor (consultor_id),
  KEY idx_cu_unidade   (unidade_id),
  CONSTRAINT fk_cu_consultor
    FOREIGN KEY (consultor_id) REFERENCES consultores (id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_cu_unidade
    FOREIGN KEY (unidade_id) REFERENCES unidades (id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_cu_vigencia CHECK (
    vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio
  )
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 2) Backfill: cria 1 vínculo vigente por consultor a partir da unidade antiga.
--    SÓ roda se `consultores.unidade_id` ainda existir (banco não migrado).
--    Em banco já migrado a coluna não existe, então isto vira um no-op.
--    (Usa SQL dinâmico para não dar erro "Unknown column unidade_id".)
-- -----------------------------------------------------------------------------
SET @tem_unidade_id := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE()
    AND table_name   = 'consultores'
    AND column_name  = 'unidade_id'
);
SET @sql_backfill := IF(@tem_unidade_id > 0,
  'INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
   SELECT c.id, c.unidade_id,
          COALESCE((SELECT MIN(l.mes) FROM lancamentos l WHERE l.consultor_id = c.id), ''2000-01-01''),
          NULL
   FROM consultores c',
  'SELECT 1');
PREPARE _bf FROM @sql_backfill;
EXECUTE _bf;
DEALLOCATE PREPARE _bf;

-- -----------------------------------------------------------------------------
-- 3) Garante que a Nissan Ceasa exista (ajuste loja/gerente se precisar).
-- -----------------------------------------------------------------------------
INSERT INTO unidades (marca, loja, nome_exibicao, gerente)
SELECT 'Nissan', 'Ceasa', 'Nissan Ceasa', NULL
WHERE NOT EXISTS (
  SELECT 1 FROM unidades WHERE nome_exibicao = 'Nissan Ceasa'
);

-- -----------------------------------------------------------------------------
-- 4) TRANSFERÊNCIA DO RAFAEL (idempotente).
--    4a) Fecha a Braz Leme em Junho/2026 (Jun p/ trás continua na Braz Leme).
--    4b) Abre a Ceasa a partir de Julho/2026.
--    4c) Lançamento placeholder de Julho com zeros -> aparece na Ceasa com total 0.
--        (dados dele vão só até 05/2026; a view só mostra meses com lançamento)
-- -----------------------------------------------------------------------------
UPDATE consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
SET cu.vigencia_fim = '2026-06-01'
WHERE c.nome = 'Rafael Alves de Sa'
  AND u.nome_exibicao = 'Nissan Braz Leme'
  AND cu.vigencia_fim IS NULL;

INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT c.id, u.id, '2026-07-01', NULL
FROM consultores c
JOIN unidades u ON u.nome_exibicao = 'Nissan Ceasa'
WHERE c.nome = 'Rafael Alves de Sa';

INSERT IGNORE INTO lancamentos (consultor_id, mes, passagens, refil_diant, refil_tras)
SELECT c.id, '2026-07-01', 0, 0, 0
FROM consultores c
WHERE c.nome = 'Rafael Alves de Sa';

-- -----------------------------------------------------------------------------
-- 5) (Re)cria a view resolvendo a unidade pelo MÊS do lançamento (idempotente).
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
JOIN consultores       c  ON c.id  = l.consultor_id
JOIN consultor_unidade cu ON cu.consultor_id = l.consultor_id
                         AND l.mes >= cu.vigencia_inicio
                         AND (cu.vigencia_fim IS NULL OR l.mes <= cu.vigencia_fim)
JOIN unidades          u  ON u.id  = cu.unidade_id
JOIN precos_marca      p  ON p.marca = u.marca;

-- -----------------------------------------------------------------------------
-- CONFERÊNCIA (rode depois): Braz Leme em 02–05/2026 e Ceasa em 07/2026 (total 0).
-- -----------------------------------------------------------------------------
-- SELECT consultor, unidade, mes_label, total_geral
-- FROM vw_base_tidy WHERE consultor = 'Rafael Alves de Sa' ORDER BY mes;
