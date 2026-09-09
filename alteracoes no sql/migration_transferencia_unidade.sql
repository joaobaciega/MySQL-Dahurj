-- =============================================================================
--  Migração: unidade por MÊS (histórico de lotação) + transferência do Rafael
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  CONTEXTO
--    A Nissan Braz Leme fechou. O consultor Rafael passou à Nissan Ceasa a
--    partir de JULHO/2026. Precisamos transferi-lo SEM perder o histórico de
--    Junho/2026 e anteriores (que deve continuar contando para a Braz Leme).
--
--  O QUE ESTA MIGRAÇÃO FAZ
--    1) Cria a tabela `consultor_unidade` (vínculo consultor↔unidade com vigência).
--    2) Faz backfill: cada consultor atual vira um vínculo VIGENTE (fim = NULL).
--    3) Transfere o Rafael: fecha Braz Leme em Jun/2026 e abre Ceasa em Jul/2026.
--    4) Remove `consultores.unidade_id` (a unidade deixa de ser do consultor).
--    5) Recria a view `vw_base_tidy` resolvendo a unidade pelo MÊS do lançamento.
--
--  COMO RODAR
--      mysql -u root -p dashboard_dahruj < migration_transferencia_unidade.sql
--
--  RECOMENDADO: faça backup antes.
--      mysqldump -u root -p dashboard_dahruj > backup_antes_migracao.sql
--
--  ANTES DE RODAR, confira os nomes EXATOS no seu banco e ajuste abaixo se
--  necessário (as strings precisam bater exatamente):
--      SELECT id, nome_exibicao FROM unidades;      -- 'Nissan Braz Leme', 'Nissan Ceasa'
--      SELECT id, nome FROM consultores;            -- 'Rafael Alves de Sa'
-- =============================================================================

USE dashboard_dahruj;

-- Roda tudo em uma transação: ou aplica inteiro, ou nada.
START TRANSACTION;

-- -----------------------------------------------------------------------------
-- 0) Garante que a Nissan Ceasa exista (destino da transferência).
--    Ajuste loja/gerente conforme o seu cadastro. Se já existir, nada muda.
-- -----------------------------------------------------------------------------
INSERT INTO unidades (marca, loja, nome_exibicao, gerente)
SELECT 'Nissan', 'Ceasa', 'Nissan Ceasa', NULL
WHERE NOT EXISTS (
  SELECT 1 FROM unidades WHERE nome_exibicao = 'Nissan Ceasa'
);

-- -----------------------------------------------------------------------------
-- 1) Nova tabela de vínculo com vigência.
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
-- 2) Backfill: cada consultor existente ganha 1 vínculo VIGENTE na sua unidade
--    atual. A vigência começa no 1º mês com lançamento (ou 2000-01-01 se nenhum),
--    garantindo que todo o histórico já existente seja coberto pela view.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO consultor_unidade
    (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT c.id,
       c.unidade_id,
       COALESCE((SELECT MIN(l.mes) FROM lancamentos l WHERE l.consultor_id = c.id),
                '2000-01-01'),
       NULL
FROM consultores c;

-- -----------------------------------------------------------------------------
-- 3) TRANSFERÊNCIA DO RAFAEL
--    3a) Fecha o vínculo na Braz Leme em Junho/2026 (Junho continua na Braz Leme).
--    3b) Abre o vínculo na Ceasa a partir de Julho/2026.
--    Rafael mantém o MESMO id → todos os lançamentos de Junho p/ trás seguem
--    ligados a ele e passam a exibir a unidade certa (Braz Leme) pela vigência.
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

--    3c) Lançamento placeholder de Julho/2026 com zeros. Como os dados do Rafael
--        vão só até 05/2026 e a view só exibe meses com lançamento, esta linha faz
--        ele aparecer em 07/2026 na Ceasa com total geral = 0. INSERT IGNORE na
--        chave (consultor_id, mes) => não sobrescreve vendas reais que entrem depois.
INSERT IGNORE INTO lancamentos (consultor_id, mes, passagens, refil_diant, refil_tras)
SELECT c.id, '2026-07-01', 0, 0, 0
FROM consultores c
WHERE c.nome = 'Rafael Alves de Sa';

-- -----------------------------------------------------------------------------
-- 4) A unidade deixa de ser atributo do consultor.
--    Remove a FK, o índice, o UNIQUE(nome, unidade_id) e a coluna unidade_id;
--    a identidade do consultor passa a ser só o nome.
--
--    OBS: se algum NOME de consultor existir em MAIS DE UMA unidade no cadastro
--    antigo (duas linhas), o UNIQUE(nome) abaixo vai falhar. Rode antes:
--      SELECT nome, COUNT(*) FROM consultores GROUP BY nome HAVING COUNT(*) > 1;
--    e unifique manualmente esses casos (é justamente o cenário de transferência).
-- -----------------------------------------------------------------------------
ALTER TABLE consultores DROP FOREIGN KEY fk_consultor_unidade;
ALTER TABLE consultores DROP INDEX idx_consultor_unidade;
ALTER TABLE consultores DROP INDEX uq_consultor;
ALTER TABLE consultores DROP COLUMN unidade_id;
ALTER TABLE consultores ADD UNIQUE KEY uq_consultor (nome);

-- -----------------------------------------------------------------------------
-- 5) View: resolve a unidade pelo MÊS do lançamento (via consultor_unidade).
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_base_tidy;
CREATE VIEW vw_base_tidy AS
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

COMMIT;

-- -----------------------------------------------------------------------------
-- CONFERÊNCIA (rode depois; não faz parte da transação)
--   Deve mostrar Rafael na Braz Leme até 06/2026 e na Ceasa de 07/2026 em diante.
-- -----------------------------------------------------------------------------
-- SELECT consultor, unidade, mes_label, total_geral
-- FROM vw_base_tidy WHERE consultor = 'Rafael Alves de Sa' ORDER BY mes;
