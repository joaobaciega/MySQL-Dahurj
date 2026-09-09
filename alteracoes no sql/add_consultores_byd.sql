-- =============================================================================
--  Cadastro: 2 consultores novos em unidades BYD já existentes
--    Guilherme Soares -> BYD Ceasa       (unidade id 14)
--    Ismael           -> BYD Aricanduva  (unidade id 15)
--  Banco: dashboard_dahruj  (MySQL 8.0+ / Aiven)
--
--  CONTEXTO
--    Um consultor aparece na tela de Lançamento quando tem vínculo VIGENTE em
--    `consultor_unidade` (vigencia_fim IS NULL) — ver db.listar_consultores().
--    Logo são 2 passos: gravar a PESSOA em `consultores` e abrir o vínculo com
--    a unidade. As unidades BYD já existem (conferido: ids 14 e 15), este script
--    não cria nem altera unidade nenhuma.
--
--  VIGÊNCIA
--    @vig = primeiro mês do consultor na unidade (sempre dia 1). Está em
--    2026-08-01 (mês corrente). Troque para '2026-07-01' se precisarem lançar
--    julho — a tela de Lançamento só olha vigencia_fim, mas a data certa mantém
--    o histórico de lotação fiel.
--
--  IDEMPOTENTE: os dois passos são INSERT IGNORE sobre chaves únicas
--  (consultores.nome e uq_cu). Rodar de novo não duplica nada.
--
--  COMO RODAR (MySQL Workbench)
--    "Execute ALL" — o raio simples (Ctrl+Shift+Enter). O raio com cursor
--    (Ctrl+Enter) roda só a linha do cursor. Depois recarregue o Streamlit
--    (o cache de consultores expira em 60s).
-- =============================================================================

USE dashboard_dahruj;

SET NAMES utf8mb4;
SET autocommit = 1;

SET @vig := '2026-08-01';

-- Unidades resolvidas por marca+loja (chave única uq_unidade), não pelo nome de
-- exibição: é o que a conferência anterior provou funcionar (14 e 15).
SET @u_ceasa := (SELECT id FROM unidades WHERE marca = 'BYD' AND loja = 'Ceasa'      LIMIT 1);
SET @u_arica := (SELECT id FROM unidades WHERE marca = 'BYD' AND loja = 'Aricanduva' LIMIT 1);

-- Coluna LEGADA consultores.unidade_id: onde existe é NOT NULL sem default, e um
-- INSERT IGNORE sem ela descarta a linha EM SILÊNCIO. Daí o SQL dinâmico — não
-- se pode citar uma coluna que talvez não exista.
SET @tem_uid := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'consultores'
    AND column_name = 'unidade_id'
);

-- -----------------------------------------------------------------------------
-- 1) Consultores (identidade = nome; não duplica quem já existe).
-- -----------------------------------------------------------------------------
SET @sql := IF(@tem_uid > 0,
  'INSERT IGNORE INTO consultores (nome, unidade_id)
     VALUES (''Guilherme Soares'', @u_ceasa), (''Ismael'', @u_arica)',
  'INSERT IGNORE INTO consultores (nome)
     VALUES (''Guilherme Soares''), (''Ismael'')');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

SET @c_gui := (SELECT id FROM consultores WHERE nome = 'Guilherme Soares' ORDER BY id LIMIT 1);
SET @c_isa := (SELECT id FROM consultores WHERE nome = 'Ismael'           ORDER BY id LIMIT 1);

-- CHECKPOINT A — os dois ids têm de vir preenchidos. NULL = o insert do
-- consultor foi barrado (aí me mande o valor de @tem_uid abaixo).
SELECT @c_gui AS id_guilherme, @c_isa AS id_ismael,
       @tem_uid AS tem_coluna_legada;

-- -----------------------------------------------------------------------------
-- 2) Vínculo vigente (vigencia_fim = NULL) => é o que lista na tela.
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
VALUES
  (@c_gui, @u_ceasa, @vig, NULL),
  (@c_isa, @u_arica, @vig, NULL);

COMMIT;

-- -----------------------------------------------------------------------------
-- CHECKPOINT B (final) — esperado: exatamente 2 linhas
--   Guilherme Soares | BYD Ceasa      | 2026-08-01 | NULL
--   Ismael           | BYD Aricanduva | 2026-08-01 | NULL
-- -----------------------------------------------------------------------------
SELECT c.nome AS consultor, u.nome_exibicao AS unidade,
       cu.vigencia_inicio, cu.vigencia_fim
FROM consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
WHERE c.nome IN ('Guilherme Soares', 'Ismael')
ORDER BY c.nome;

-- -----------------------------------------------------------------------------
-- OPCIONAL — só se o CHECKPOINT B mostrar o MESMO consultor com mais de um
-- vínculo vigente (nome já usado em outra loja => apareceria nas duas telas).
-- Fecha o vínculo ANTIGO no mês anterior ao da entrada na BYD:
-- -----------------------------------------------------------------------------
-- UPDATE consultor_unidade cu
--   JOIN consultores c ON c.id = cu.consultor_id
--   JOIN unidades    u ON u.id = cu.unidade_id
--    SET cu.vigencia_fim = DATE_SUB(@vig, INTERVAL 1 MONTH)
--  WHERE c.nome IN ('Guilherme Soares', 'Ismael')
--    AND cu.vigencia_fim IS NULL
--    AND u.marca <> 'BYD';
