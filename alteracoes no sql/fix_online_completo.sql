-- =============================================================================
--  MIGRAÇÃO CONSOLIDADA — banco ONLINE  (dashboard_dahruj, MySQL 8.0+)
--
--  OBJETIVO
--    Levar o banco do esquema ANTIGO (consultores.unidade_id, SEM a tabela
--    consultor_unidade, lancamentos SEM unidade_id) para o esquema FINAL que o
--    app atual (app.py / db.py) espera:
--      * tabela consultor_unidade (lotação vigente por consultor)
--      * lancamentos.unidade_id + UNIQUE (consultor_id, mes, unidade_id)
--      * view vw_base_tidy resolvendo a unidade pelo PRÓPRIO lançamento
--
--  É IDEMPOTENTE: pode rodar mais de uma vez sem duplicar nem quebrar.
--  PRESERVA todo o histórico já lançado.
--
--  COMO RODAR
--    1) FAÇA BACKUP antes (export do banco no seu painel/host MySQL online).
--    2) Cole e execute TUDO de uma vez no console SQL do seu banco ONLINE
--       (o mesmo lugar onde o schema.sql foi aplicado — phpMyAdmin, Workbench
--       conectado ao host online, console do provedor, etc.).
--    3) Volte no app do Streamlit e clique em "Rerun" (ou recarregue a página).
--
--  OBS: este script NÃO faz a transferência específica do Rafael (Braz Leme →
--  Ceasa). Ele só corrige o ESQUEMA para o app voltar a funcionar. Se a
--  transferência do Rafael ainda precisar ser feita, rode depois o script
--  migrar_unidade_no_lancamento.sql (passo 4) OU ajuste pela tela de Lançamento.
-- =============================================================================

USE dashboard_dahruj;

-- Desliga o "safe update mode" do MySQL Workbench SÓ NESTA SESSÃO. Sem isto, o
-- Workbench bloqueia os UPDATE de backfill (Error 1175), mesmo com WHERE válido.
-- É reativado no fim do script.
SET SQL_SAFE_UPDATES = 0;

-- -----------------------------------------------------------------------------
-- 1) Tabela de vínculo consultor<->unidade com vigência (idempotente).
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
-- 2) Backfill do vínculo a partir de consultores.unidade_id.
--    Só roda se a coluna antiga ainda existir (banco não migrado). Cada
--    consultor vira 1 vínculo VIGENTE (fim = NULL) na sua unidade atual,
--    começando no 1º lançamento (ou 2000-01-01) para cobrir todo o histórico.
-- -----------------------------------------------------------------------------
SET @tem_unidade_id := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE()
    AND table_name = 'consultores' AND column_name = 'unidade_id'
);
SET @sql := IF(@tem_unidade_id > 0,
  'INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
     SELECT c.id, c.unidade_id,
            COALESCE((SELECT MIN(l.mes) FROM lancamentos l WHERE l.consultor_id = c.id), ''2000-01-01''),
            NULL
     FROM consultores c',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- -----------------------------------------------------------------------------
-- 3) Coluna lancamentos.unidade_id (nullable primeiro; MySQL não tem
--    ADD COLUMN IF NOT EXISTS, então guardamos por information_schema).
-- -----------------------------------------------------------------------------
SET @tem_col := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE()
    AND table_name = 'lancamentos' AND column_name = 'unidade_id'
);
SET @sql := IF(@tem_col = 0,
  'ALTER TABLE lancamentos ADD COLUMN unidade_id INT NULL AFTER consultor_id',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- -----------------------------------------------------------------------------
-- 4) Backfill de lancamentos.unidade_id pela vigência do vínculo (só linhas
--    ainda nulas => rodar de novo é no-op).
-- -----------------------------------------------------------------------------
UPDATE lancamentos l
JOIN consultor_unidade cu
  ON cu.consultor_id = l.consultor_id
 AND l.mes >= cu.vigencia_inicio
 AND (cu.vigencia_fim IS NULL OR l.mes <= cu.vigencia_fim)
SET l.unidade_id = cu.unidade_id
WHERE l.unidade_id IS NULL;

-- -----------------------------------------------------------------------------
-- 5) Torna unidade_id NOT NULL apenas se o backfill cobriu tudo.
--    (Se sobrar alguma linha nula, a coluna fica nullable e a view a ignora.)
-- -----------------------------------------------------------------------------
SET @nulos := (SELECT COUNT(*) FROM lancamentos WHERE unidade_id IS NULL);
SELECT IF(@nulos = 0,
          'Backfill OK: nenhum lancamento sem unidade_id.',
          CONCAT('ATENCAO: ', @nulos, ' lancamento(s) sem unidade_id. Coluna mantida NULLABLE.')
       ) AS status_backfill;
SET @col_nn := (
  SELECT is_nullable FROM information_schema.columns
  WHERE table_schema = DATABASE()
    AND table_name = 'lancamentos' AND column_name = 'unidade_id'
);
SET @sql := IF(@nulos = 0 AND @col_nn = 'YES',
  'ALTER TABLE lancamentos MODIFY COLUMN unidade_id INT NOT NULL',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- -----------------------------------------------------------------------------
-- 6) Troca a UNIQUE (consultor_id, mes) -> (consultor_id, mes, unidade_id).
--    Via índice temporário para não derrubar o suporte à FK de consultor_id.
-- -----------------------------------------------------------------------------
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
SET @sql := IF(@uq_cols <> 'consultor_id,mes,unidade_id' AND @tem_v2 = 0,
  'ALTER TABLE lancamentos ADD UNIQUE KEY uq_lancamento_v2 (consultor_id, mes, unidade_id)',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

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

-- -----------------------------------------------------------------------------
-- 7) Índice de apoio + FK de unidade_id (idempotentes).
-- -----------------------------------------------------------------------------
SET @tem_idx := (
  SELECT COUNT(*) FROM information_schema.statistics
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND index_name = 'idx_lancamento_unidade'
);
SET @sql := IF(@tem_idx = 0,
  'ALTER TABLE lancamentos ADD KEY idx_lancamento_unidade (unidade_id)',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

SET @tem_fk := (
  SELECT COUNT(*) FROM information_schema.table_constraints
  WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
    AND constraint_type = 'FOREIGN KEY' AND constraint_name = 'fk_lancamento_unidade'
);
SET @sql := IF(@tem_fk = 0 AND @nulos = 0,
  'ALTER TABLE lancamentos ADD CONSTRAINT fk_lancamento_unidade
     FOREIGN KEY (unidade_id) REFERENCES unidades (id)
     ON UPDATE CASCADE ON DELETE RESTRICT',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- -----------------------------------------------------------------------------
-- 8) TRANSFERÊNCIA DO RAFAEL para a Nissan Ceasa (idempotente).
--    Afeta só a TELA de Lançamento (quem aparece em cada unidade). O histórico
--    já lançado NÃO muda, porque a view lê a unidade de lancamentos.unidade_id.
--    - Garante que a Nissan Ceasa exista.
--    - Fecha o vínculo na Braz Leme (fim = 2026-05-01).
--    - Abre/ajusta o vínculo na Ceasa vigente a partir de 2026-06-01.
--    Se ele JÁ estiver na Ceasa, estes comandos não mudam nada.
-- -----------------------------------------------------------------------------
INSERT INTO unidades (marca, loja, nome_exibicao, gerente)
SELECT 'Nissan', 'Ceasa', 'Nissan Ceasa', NULL
WHERE NOT EXISTS (SELECT 1 FROM unidades WHERE nome_exibicao = 'Nissan Ceasa');

UPDATE consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
SET cu.vigencia_fim = '2026-05-01'
WHERE c.nome = 'Rafael Alves de Sa'
  AND u.nome_exibicao = 'Nissan Braz Leme';

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
-- 9) View final: unidade resolvida pelo PRÓPRIO lançamento (l.unidade_id).
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

-- Reativa o safe update mode (volta ao padrão do Workbench).
SET SQL_SAFE_UPDATES = 1;

-- -----------------------------------------------------------------------------
-- 10) Conferência (deve retornar números coerentes; linhas_view > 0).
-- -----------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM consultor_unidade)                       AS vinculos,
  (SELECT COUNT(*) FROM lancamentos WHERE unidade_id IS NULL)    AS lancamentos_sem_unidade,
  (SELECT COUNT(*) FROM vw_base_tidy)                            AS linhas_view;

-- Conferência do Rafael: a linha com vigencia_fim NULL mostra a unidade ATUAL
-- dele (deve ser 'Nissan Ceasa'). As demais linhas são o histórico de lotação.
SELECT c.nome, u.nome_exibicao AS unidade_atual, cu.vigencia_inicio, cu.vigencia_fim
FROM consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
WHERE c.nome = 'Rafael Alves de Sa'
ORDER BY cu.vigencia_inicio;
