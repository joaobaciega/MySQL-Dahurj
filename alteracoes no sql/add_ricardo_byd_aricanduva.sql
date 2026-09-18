-- =============================================================================
--  Cadastro: consultor "Ricardo" na BYD Aricanduva
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  O QUE FAZ (idempotente — pode rodar mais de uma vez sem duplicar):
--    1) Cria a pessoa em `consultores` (identidade = nome).
--    2) Abre o vínculo vigente na BYD Aricanduva a partir de @mes
--       (vigencia_fim = NULL) — é isso que o faz aparecer na tela de Lançamento.
--    NÃO cria lançamento: os números você digita normalmente pelo app.
--
--  COMO RODAR
--    Cole TUDO de uma vez no console MySQL ONLINE (o local está desatualizado).
--    Depois recarregue o app do Streamlit.
-- =============================================================================

USE dashboard_dahruj;

-- Charset (nomes com acento) e gravação efetiva em console com autocommit off.
SET NAMES utf8mb4;
SET autocommit = 1;

-- -----------------------------------------------------------------------------
-- PARÂMETROS
--   @nome: grafia exata que vai aparecer no dashboard. Se o nome completo for
--          conhecido (ex.: 'Ricardo Alves'), troque aqui ANTES de rodar — mudar
--          depois exige UPDATE, porque o nome é a identidade do consultor.
--   @mes : primeiro mês na unidade. Não limita o que pode ser lançado (a tela
--          lista pela lotação vigente), serve de registro. Se ele já tem número
--          de agosto, use '2026-08-01'.
-- -----------------------------------------------------------------------------
SET @nome := 'Ricardo';
SET @mes  := '2026-09-01';

SET @u := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Aricanduva');

-- -----------------------------------------------------------------------------
-- DIAGNÓSTICO — alguém parecido já existe? Se aparecer um "Ricardo <sobrenome>"
-- que é a MESMA pessoa, PARE: em vez de cadastrar de novo, use o script de
-- transferência (fecha o vínculo antigo e abre o da BYD Aricanduva).
-- -----------------------------------------------------------------------------
SELECT c.id, c.nome,
       IFNULL(GROUP_CONCAT(DISTINCT u.nome_exibicao ORDER BY u.nome_exibicao SEPARATOR ' | '),
              '(sem vinculo)') AS unidades
FROM consultores c
LEFT JOIN consultor_unidade cu ON cu.consultor_id = c.id
LEFT JOIN unidades          u  ON u.id = cu.unidade_id
WHERE c.nome LIKE 'Ricardo%'
GROUP BY c.id, c.nome
ORDER BY c.nome;

-- Coluna LEGADA consultores.unidade_id: NOT NULL sem default em bancos migrados
-- só em parte. Sem preencher, o INSERT IGNORE descarta a linha em silêncio
-- (strict mode) e nenhum consultor é gravado. Guardado por SQL dinâmico porque
-- não dá para citar uma coluna que talvez não exista.
SET @tem_uid := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'consultores'
    AND column_name = 'unidade_id'
);

SELECT IF(@u IS NULL,
          'ERRO: unidade BYD Aricanduva nao encontrada. Nada sera gravado.',
          CONCAT('OK: BYD Aricanduva id=', @u, '  |  cadastrando "', @nome,
                 '" a partir de ', @mes)) AS status_alvo;

-- -----------------------------------------------------------------------------
-- 1) A pessoa (INSERT IGNORE => não duplica se o nome já existir).
-- -----------------------------------------------------------------------------
SET @sql := IF(@tem_uid > 0,
  'INSERT IGNORE INTO consultores (nome, unidade_id) SELECT @nome, @u FROM DUAL WHERE @u IS NOT NULL',
  'INSERT IGNORE INTO consultores (nome) SELECT @nome FROM DUAL WHERE @u IS NOT NULL');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

SET @c := (SELECT id FROM consultores WHERE nome = @nome ORDER BY id LIMIT 1);

SELECT IF(@c IS NULL,
          'ERRO: o consultor NAO foi gravado. Verifique a coluna legada consultores.unidade_id.',
          CONCAT('OK: consultor id=', @c)) AS status_consultor;

-- -----------------------------------------------------------------------------
-- 2) Vínculo vigente na BYD Aricanduva (fim = NULL => aparece na tela).
--    INSERT IGNORE na chave (consultor_id, unidade_id, vigencia_inicio).
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT @c, @u, @mes, NULL FROM DUAL
 WHERE @c IS NOT NULL AND @u IS NOT NULL;

-- Garante vigente caso a linha já existisse fechada.
UPDATE consultor_unidade
   SET vigencia_fim = NULL
 WHERE consultor_id = @c AND unidade_id = @u AND vigencia_inicio = @mes;

COMMIT;

-- =============================================================================
-- CONFERÊNCIA — esperado: 1 linha, BYD Aricanduva, 2026-09-01, VIGENTE.
-- Ao lado, os demais consultores vigentes da unidade (Vanessa Gobbetti, etc.).
-- =============================================================================
SELECT c.nome AS consultor, u.nome_exibicao AS unidade,
       cu.vigencia_inicio, cu.vigencia_fim,
       IF(cu.vigencia_fim IS NULL, 'VIGENTE', 'encerrado') AS situacao
FROM consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
WHERE u.id = @u
ORDER BY situacao, c.nome;
