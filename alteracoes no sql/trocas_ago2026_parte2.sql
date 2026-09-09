-- =============================================================================
--  Trocas de Agosto/2026 — parte 2
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  O QUE FAZ (idempotente — pode rodar mais de uma vez sem efeito colateral):
--    1) Beatriz Santos:  BYD Ceasa          -> BYD Vila Guilherme
--    2) Renan (Hui):     BYD Vila Guilherme -> BYD Ceasa      (troca cruzada)
--    3) Andrea Sonobe Silveira: consultora NOVA na Jeep Ceasa
--
--  HISTÓRICO PRESERVADO
--    A unidade fica gravada em CADA lançamento (lancamentos.unidade_id) e é dali
--    que a view vw_base_tidy lê. O que já foi lançado NÃO se move: julho da
--    Beatriz continua na BYD Ceasa e julho do Renan na BYD Vila Guilherme.
--    Este script só mexe no vínculo VIGENTE (`consultor_unidade`), que é o que
--    define em qual unidade a pessoa aparece na tela de Lançamento.
--    Fechando o vínculo antigo em 2026-07-01 (fim é INCLUSIVO), julho continua
--    contando na loja antiga e agosto em diante cai na loja nova.
--
--  COMO RODAR
--    Faça backup (export) antes. Cole e execute TUDO de uma vez no console MySQL
--    online. Depois recarregue o app do Streamlit e lance agosto normalmente.
-- =============================================================================

USE dashboard_dahruj;

-- Nomes com acento e gravação efetiva mesmo em console com autocommit desligado.
SET NAMES utf8mb4;
SET autocommit = 1;

-- -----------------------------------------------------------------------------
-- PARÂMETRO ÚNICO: mês a partir do qual valem as trocas / entra a Andrea.
-- -----------------------------------------------------------------------------
SET @mes := '2026-08-01';
SET @fim := DATE_SUB(@mes, INTERVAL 1 MONTH);   -- último mês na loja antiga

-- Coluna LEGADA consultores.unidade_id: existe em bancos migrados só em parte e,
-- sendo NOT NULL sem default, faz o INSERT da consultora nova ser DESCARTADO em
-- silêncio se não for preenchida. Por isso o guard por information_schema.
SET @tem_uid := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'consultores'
    AND column_name = 'unidade_id'
);

-- Sanidade: confirma que a unidade é lida do lançamento (modelo atual). Se vier
-- ATENCAO, PARE e rode antes o migrar_unidade_no_lancamento.sql — sem essa
-- coluna, mudar a vigência REESCREVE o histórico das duas transferências.
SELECT IF((SELECT COUNT(*) FROM information_schema.columns
            WHERE table_schema = DATABASE() AND table_name = 'lancamentos'
              AND column_name = 'unidade_id') > 0,
          'OK: historico preservado (lancamentos.unidade_id existe).',
          'ATENCAO: lancamentos.unidade_id NAO existe - rode migrar_unidade_no_lancamento.sql ANTES.')
       AS status_modelo;

-- =============================================================================
-- 1) BEATRIZ SANTOS — BYD Ceasa -> BYD Vila Guilherme
-- =============================================================================
SET @u_de   := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Ceasa');
SET @u_para := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Vila Guilherme');

-- Identifica a PESSOA pelo vínculo com a loja de origem (evita homônimo de outra
-- marca). Sem vínculo, cai para o nome — só se for único.
SET @c_bea := (
  SELECT cu.consultor_id
  FROM consultor_unidade cu
  JOIN consultores c ON c.id = cu.consultor_id
  WHERE c.nome = 'Beatriz Santos' AND cu.unidade_id = @u_de
  ORDER BY (cu.vigencia_fim IS NULL) DESC, cu.vigencia_inicio DESC
  LIMIT 1
);
SET @c_bea := IF(@c_bea IS NULL
                 AND (SELECT COUNT(*) FROM consultores WHERE nome = 'Beatriz Santos') = 1,
                 (SELECT id FROM consultores WHERE nome = 'Beatriz Santos'),
                 @c_bea);

SELECT IF(@c_bea IS NULL OR @u_para IS NULL,
          'ERRO: confira o nome exato da consultora / a unidade BYD Vila Guilherme. Nada foi alterado no item 1.',
          CONCAT('OK item 1: Beatriz id=', @c_bea, ' -> unidade id=', @u_para)) AS status_beatriz;

-- 1a) Fecha o vínculo da BYD Ceasa em @fim (filtro inicio <= @fim respeita o CHECK).
UPDATE consultor_unidade
   SET vigencia_fim = @fim
 WHERE consultor_id = @c_bea
   AND unidade_id   = @u_de
   AND vigencia_inicio <= @fim
   AND (vigencia_fim IS NULL OR vigencia_fim > @fim);

-- 1b) Abre o vínculo da BYD Vila Guilherme a partir de @mes.
INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT @c_bea, @u_para, @mes, NULL FROM DUAL
 WHERE @c_bea IS NOT NULL AND @u_para IS NOT NULL;

-- 1c) Garante que esse vínculo esteja VIGENTE (caso a linha já existisse fechada).
UPDATE consultor_unidade
   SET vigencia_fim = NULL
 WHERE consultor_id = @c_bea AND unidade_id = @u_para AND vigencia_inicio = @mes;

-- 1d) Coluna legada, se existir (UPDATE IGNORE: nunca aborta o script).
SET @sql := IF(@tem_uid > 0,
  'UPDATE IGNORE consultores SET unidade_id = @u_para WHERE id = @c_bea',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- =============================================================================
-- 2) RENAN — BYD Vila Guilherme -> BYD Ceasa
--    O cadastro trouxe "Renan Hui" (add_byd.sql); o LIKE aceita as duas formas,
--    e o vínculo com a Vila Guilherme garante que é a pessoa certa.
-- =============================================================================
SET @u_de   := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Vila Guilherme');
SET @u_para := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Ceasa');

SET @c_ren := (
  SELECT cu.consultor_id
  FROM consultor_unidade cu
  JOIN consultores c ON c.id = cu.consultor_id
  WHERE c.nome LIKE 'Renan%' AND cu.unidade_id = @u_de
  ORDER BY (cu.vigencia_fim IS NULL) DESC, cu.vigencia_inicio DESC
  LIMIT 1
);
SET @c_ren := IF(@c_ren IS NULL
                 AND (SELECT COUNT(*) FROM consultores WHERE nome LIKE 'Renan%') = 1,
                 (SELECT id FROM consultores WHERE nome LIKE 'Renan%'),
                 @c_ren);

SELECT IF(@c_ren IS NULL OR @u_para IS NULL,
          'ERRO: confira o nome exato do consultor / a unidade BYD Ceasa. Nada foi alterado no item 2.',
          CONCAT('OK item 2: Renan id=', @c_ren, ' (',
                 (SELECT nome FROM consultores WHERE id = @c_ren),
                 ') -> unidade id=', @u_para)) AS status_renan;

-- 2a) Fecha o vínculo da BYD Vila Guilherme.
UPDATE consultor_unidade
   SET vigencia_fim = @fim
 WHERE consultor_id = @c_ren
   AND unidade_id   = @u_de
   AND vigencia_inicio <= @fim
   AND (vigencia_fim IS NULL OR vigencia_fim > @fim);

-- 2b) Abre o vínculo da BYD Ceasa a partir de @mes.
INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT @c_ren, @u_para, @mes, NULL FROM DUAL
 WHERE @c_ren IS NOT NULL AND @u_para IS NOT NULL;

-- 2c) Garante vigente.
UPDATE consultor_unidade
   SET vigencia_fim = NULL
 WHERE consultor_id = @c_ren AND unidade_id = @u_para AND vigencia_inicio = @mes;

-- 2d) Coluna legada, se existir.
SET @sql := IF(@tem_uid > 0,
  'UPDATE IGNORE consultores SET unidade_id = @u_para WHERE id = @c_ren',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- =============================================================================
-- 3) ANDREA SONOBE SILVEIRA — consultora NOVA na Jeep Ceasa
--    Sem lançamento placeholder: ela aparece na tela de Lançamento assim que o
--    vínculo existir, e entra no dashboard quando agosto for lançado.
-- =============================================================================
SET @u_para := (SELECT id FROM unidades WHERE nome_exibicao = 'Jeep Ceasa');

SELECT IF(@u_para IS NULL,
          'ERRO: unidade Jeep Ceasa nao encontrada. Item 3 nao sera aplicado.',
          CONCAT('OK item 3: Jeep Ceasa id=', @u_para)) AS status_jeep_ceasa;

-- 3a) Cadastra a pessoa (INSERT IGNORE => não duplica se já existir).
--     Com a coluna legada, é OBRIGATÓRIO preencher unidade_id, senão a linha é
--     descartada em silêncio (strict mode + IGNORE) e nada é inserido.
SET @sql := IF(@tem_uid > 0,
  'INSERT IGNORE INTO consultores (nome, unidade_id) SELECT ''Andrea Sonobe Silveira'', @u_para FROM DUAL WHERE @u_para IS NOT NULL',
  'INSERT IGNORE INTO consultores (nome) SELECT ''Andrea Sonobe Silveira'' FROM DUAL WHERE @u_para IS NOT NULL');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

SET @c_and := (SELECT id FROM consultores WHERE nome = 'Andrea Sonobe Silveira' ORDER BY id LIMIT 1);

SELECT IF(@c_and IS NULL,
          'ERRO: a consultora nova NAO foi gravada. Verifique a coluna legada consultores.unidade_id.',
          CONCAT('OK item 3: Andrea Sonobe Silveira id=', @c_and)) AS status_andrea;

-- 3b) Vínculo vigente na Jeep Ceasa a partir de @mes.
INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT @c_and, @u_para, @mes, NULL FROM DUAL
 WHERE @c_and IS NOT NULL AND @u_para IS NOT NULL;

UPDATE consultor_unidade
   SET vigencia_fim = NULL
 WHERE consultor_id = @c_and AND unidade_id = @u_para AND vigencia_inicio = @mes;

COMMIT;

-- =============================================================================
-- CONFERÊNCIA (rodam depois; não alteram nada)
--
-- Esperado no 1º SELECT:
--   Beatriz Santos          | BYD Ceasa          | 2026-07-01 | 2026-07-01 | encerrado
--   Beatriz Santos          | BYD Vila Guilherme | 2026-08-01 | NULL       | VIGENTE
--   Renan Hui               | BYD Vila Guilherme | 2026-07-01 | 2026-07-01 | encerrado
--   Renan Hui               | BYD Ceasa          | 2026-08-01 | NULL       | VIGENTE
--   Andrea Sonobe Silveira  | Jeep Ceasa         | 2026-08-01 | NULL       | VIGENTE
-- Se aparecerem DUAS linhas VIGENTES para a mesma pessoa, o fechamento não pegou
-- (a vigência antiga começava depois de @fim) — me avise com o que apareceu.
-- =============================================================================
SELECT c.nome AS consultor, u.nome_exibicao AS unidade,
       cu.vigencia_inicio, cu.vigencia_fim,
       IF(cu.vigencia_fim IS NULL, 'VIGENTE', 'encerrado') AS situacao
FROM consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
WHERE c.id IN (@c_bea, @c_ren, @c_and)
ORDER BY c.nome, cu.vigencia_inicio;

-- Histórico intacto: o que já foi lançado continua na unidade de origem.
SELECT consultor, unidade, mes_label, passagens, refil_diant, refil_tras, total_geral
FROM vw_base_tidy
WHERE consultor_id IN (@c_bea, @c_ren, @c_and)
ORDER BY consultor, mes, unidade;
