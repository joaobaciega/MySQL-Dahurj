-- =============================================================================
--  Cadastro: marca BYD + 5 lojas novas e seus consultores
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  CONTEXTO
--    Entram na base 5 concessionárias novas da marca BYD (com gerente e
--    consultores), conforme o att-byd.md. Como a BYD ainda não existe em
--    `precos_marca`, ela é cadastrada PRIMEIRO (a FK das unidades exige a marca,
--    e o app faz JOIN com precos_marca para listar/precificar a unidade).
--
--    Preços do refil BYD:  dianteiro R$ 197,90  |  traseiro R$ 98,90.
--    Vigência de entrada (tela de Lançamento): a partir de 07/2026.
--
--  O QUE FAZ (idempotente — pode rodar mais de uma vez, não duplica nem quebra):
--    1) Cadastra a marca BYD em precos_marca (com os preços acima).
--    2) Cadastra as 5 unidades BYD (marca + loja + gerente).
--    3) Cadastra os consultores (identidade = nome).
--    4) Vincula cada consultor à sua unidade (lotação vigente, fim = NULL) a
--       partir de 2026-07-01 — é isto que os faz aparecer na tela de Lançamento.
--    NÃO recria tabelas nem a view: a vw_base_tidy já mostra BYD automaticamente
--    assim que houver lançamentos nessas unidades.
--
--  COMO RODAR
--    Faça backup antes (export do banco). Depois cole/execute TUDO de uma vez no
--    console MySQL (online ou local — o mesmo lugar onde o schema.sql foi aplicado).
--    Recarregue o app do Streamlit em seguida.
--
--  OBS: nomes gravados exatamente como no att-byd.md. Se algum estiver com erro
--       de digitação (ex.: "Marcio Evalgelista"), corrija depois pela tela/UPDATE.
-- =============================================================================

USE dashboard_dahruj;

-- Garante o charset da sessão (nomes com acento: Lígia, Fábio). Sem isto, alguns
-- consoles rejeitam/abortam o INSERT dos consultores.
SET NAMES utf8mb4;

-- Garante que as gravações sejam efetivadas mesmo em consoles com autocommit
-- desligado (senão os INSERTs são descartados ao fim da sessão). Há um COMMIT
-- explícito no final também.
SET autocommit = 1;

-- -----------------------------------------------------------------------------
-- 1) Marca BYD em precos_marca (cria ou atualiza os preços).
-- -----------------------------------------------------------------------------
INSERT INTO precos_marca (marca, preco_diant, preco_tras)
VALUES ('BYD', 197.90, 98.90)
ON DUPLICATE KEY UPDATE
  preco_diant = VALUES(preco_diant),
  preco_tras  = VALUES(preco_tras);

-- -----------------------------------------------------------------------------
-- 2) Unidades BYD (chave única = marca+loja => rodar de novo só atualiza).
--    "Aricanduva" segue a grafia já usada pelas unidades Jeep/Fiat existentes
--    (o att-byd.md trazia "Aricancduva").
-- -----------------------------------------------------------------------------
INSERT INTO unidades (marca, loja, nome_exibicao, gerente)
VALUES
  ('BYD', 'Ceasa',          'BYD Ceasa',          'Bella'),
  ('BYD', 'Aricanduva',     'BYD Aricanduva',     'Leonardo'),
  ('BYD', 'Aeroporto',      'BYD Aeroporto',      'Evando'),
  ('BYD', 'Santo Amaro',    'BYD Santo Amaro',    'Spencer'),
  ('BYD', 'Vila Guilherme', 'BYD Vila Guilherme', 'Cris')
ON DUPLICATE KEY UPDATE
  nome_exibicao = VALUES(nome_exibicao),
  gerente       = VALUES(gerente);

-- -----------------------------------------------------------------------------
-- Mapa nome do consultor -> loja BYD (fonte única para os passos 3 e 4).
-- Tabela TEMPORÁRIA: some sozinha ao fim da sessão e evita repetir a lista.
-- -----------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS _byd_map;
CREATE TEMPORARY TABLE _byd_map (nome VARCHAR(120), uni VARCHAR(120));
INSERT INTO _byd_map (nome, uni) VALUES
  ('Beatriz Santos',            'BYD Ceasa'),
  ('Wagner Koiti Ashino',       'BYD Ceasa'),
  ('Cibele Cavalcante',         'BYD Aricanduva'),
  ('Vanessa Gobbetti',          'BYD Aricanduva'),
  ('Estefane Matos',            'BYD Aeroporto'),
  ('Rogerio Neves',             'BYD Aeroporto'),
  ('Victoria',                  'BYD Aeroporto'),
  ('Lígia Tolentino',           'BYD Santo Amaro'),
  ('Marcio Evalgelista Santos', 'BYD Santo Amaro'),
  ('Fábio Henrique',            'BYD Vila Guilherme'),
  ('Kely Cristina',             'BYD Vila Guilherme'),
  ('Renan Hui',                 'BYD Vila Guilherme');

-- Detecta se a tabela `consultores` ainda tem a coluna LEGADA `unidade_id`
-- (bancos migrados só em parte ainda a têm, NOT NULL e sem default). Se tiver,
-- é obrigatório preenchê-la no INSERT, senão o MySQL descarta a linha (strict +
-- INSERT IGNORE) e nenhum consultor é gravado. Guardado por SQL dinâmico porque
-- não se pode referenciar uma coluna que talvez não exista.
SET @tem_uid := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'consultores'
    AND column_name = 'unidade_id'
);

-- -----------------------------------------------------------------------------
-- 3) Consultores (INSERT IGNORE não duplica nome já existente).
--    Com coluna legada: grava (nome, unidade_id = id da loja BYD).
--    Sem a coluna (esquema final): grava só (nome).
-- -----------------------------------------------------------------------------
SET @sql := IF(@tem_uid > 0,
  'INSERT IGNORE INTO consultores (nome, unidade_id)
     SELECT m.nome, u.id FROM _byd_map m
     JOIN unidades u ON u.nome_exibicao = m.uni',
  'INSERT IGNORE INTO consultores (nome)
     SELECT m.nome FROM _byd_map m');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- -----------------------------------------------------------------------------
-- 4) Vínculo consultor<->unidade (lotação vigente a partir de 2026-07-01).
--    INSERT IGNORE na chave (consultor_id, unidade_id, vigencia_inicio) => rodar
--    de novo não duplica. vigencia_fim = NULL => aparece na tela de Lançamento.
--    No esquema legado, `c.unidade_id = u.id` garante pegar o registro BYD certo
--    mesmo se houver homônimo em outra marca.
-- -----------------------------------------------------------------------------
SET @sql := IF(@tem_uid > 0,
  'INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
     SELECT c.id, u.id, ''2026-07-01'', NULL
     FROM _byd_map m
     JOIN unidades    u ON u.nome_exibicao = m.uni
     JOIN consultores c ON c.nome = m.nome AND c.unidade_id = u.id',
  'INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
     SELECT c.id, u.id, ''2026-07-01'', NULL
     FROM _byd_map m
     JOIN unidades    u ON u.nome_exibicao = m.uni
     JOIN consultores c ON c.nome = m.nome');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

DROP TEMPORARY TABLE IF EXISTS _byd_map;

-- Efetiva tudo (importante em consoles com autocommit desligado).
COMMIT;

-- -----------------------------------------------------------------------------
-- CONFERÊNCIA (rode depois; não altera nada).
--   Esperado: 1 preço BYD, 5 unidades BYD, 12 vínculos vigentes.
-- -----------------------------------------------------------------------------
-- SELECT * FROM precos_marca WHERE marca = 'BYD';
--
-- SELECT id, nome_exibicao, gerente FROM unidades WHERE marca = 'BYD'
-- ORDER BY nome_exibicao;
--
-- SELECT u.nome_exibicao AS unidade, u.gerente, c.nome AS consultor,
--        cu.vigencia_inicio, cu.vigencia_fim
-- FROM consultor_unidade cu
-- JOIN unidades    u ON u.id = cu.unidade_id
-- JOIN consultores c ON c.id = cu.consultor_id
-- WHERE u.marca = 'BYD' AND cu.vigencia_fim IS NULL
-- ORDER BY u.nome_exibicao, c.nome;
