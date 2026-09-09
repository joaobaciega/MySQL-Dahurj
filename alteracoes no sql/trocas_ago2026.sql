-- =============================================================================
--  Trocas de Agosto/2026
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  O QUE FAZ (idempotente — pode rodar mais de uma vez sem efeito colateral):
--    1) Ivan Oliveira dos Santos:  Jeep Ceasa      -> BYD Ceasa
--    2) Cibele Cavalcante:         BYD Aricanduva  -> BYD Vila Guilherme
--    3) Fiat Nações Unidas:        gerente Adriano -> Alexandre
--
--  COMO A TRANSFERÊNCIA FUNCIONA
--    A unidade fica gravada em CADA lançamento (lancamentos.unidade_id) e é dali
--    que a view vw_base_tidy lê. Ou seja: o histórico dos dois consultores
--    CONTINUA na loja antiga — nada do passado é reescrito.
--    O que muda é o vínculo vigente em `consultor_unidade`, que é o que faz a
--    pessoa aparecer na lista da tela de Lançamento de cada unidade:
--       - fecha o vínculo da loja antiga em @fim (último mês lá, INCLUSIVO)
--       - abre o vínculo da loja nova a partir de @mes (fim = NULL => vigente)
--
--  COMO RODAR
--    Faça backup (export) antes. Cole e execute TUDO de uma vez no console MySQL
--    online. Depois recarregue o app do Streamlit.
-- =============================================================================

USE dashboard_dahruj;

-- Nomes com acento (Nações, Lígia...) e gravação efetiva mesmo em console com
-- autocommit desligado. Há COMMIT explícito no fim.
SET NAMES utf8mb4;
SET autocommit = 1;

-- -----------------------------------------------------------------------------
-- PARÂMETRO ÚNICO: mês em que as duas transferências passam a valer (dia 1).
--   Com 2026-08-01, Agosto já conta na loja NOVA e os dois somem da lista da
--   loja antiga. Se Agosto ainda precisa ser lançado na loja ANTIGA, lance
--   antes de rodar isto — ou troque para '2026-09-01' na linha abaixo.
-- -----------------------------------------------------------------------------
SET @mes := '2026-08-01';
SET @fim := DATE_SUB(@mes, INTERVAL 1 MONTH);   -- último mês na loja antiga

-- Coluna LEGADA consultores.unidade_id: existe em bancos migrados só em parte.
-- Se existir, é atualizada junto (UPDATE IGNORE, para nunca abortar o script).
SET @tem_uid := (
  SELECT COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'consultores'
    AND column_name = 'unidade_id'
);

-- =============================================================================
-- 1) IVAN OLIVEIRA DOS SANTOS — Jeep Ceasa -> BYD Ceasa
-- =============================================================================
SET @u_de   := (SELECT id FROM unidades WHERE nome_exibicao = 'Jeep Ceasa');
SET @u_para := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Ceasa');

-- Identifica a PESSOA pelo vínculo com a loja de origem (evita pegar homônimo de
-- outra marca). Se não houver vínculo, cai para o nome — só se for único.
SET @c := (
  SELECT cu.consultor_id
  FROM consultor_unidade cu
  JOIN consultores c ON c.id = cu.consultor_id
  WHERE c.nome = 'Ivan Oliveira dos Santos' AND cu.unidade_id = @u_de
  ORDER BY (cu.vigencia_fim IS NULL) DESC, cu.vigencia_inicio DESC
  LIMIT 1
);
SET @c := IF(@c IS NULL
             AND (SELECT COUNT(*) FROM consultores WHERE nome = 'Ivan Oliveira dos Santos') = 1,
             (SELECT id FROM consultores WHERE nome = 'Ivan Oliveira dos Santos'),
             @c);

SELECT IF(@c IS NULL OR @u_para IS NULL,
          'ERRO: confira o nome exato do consultor / a unidade BYD Ceasa. Nada foi alterado no item 1.',
          CONCAT('OK item 1: consultor id=', @c, ' -> unidade id=', @u_para)) AS status_ivan;

-- 1a) Fecha o vínculo da Jeep Ceasa em @fim.
--     O filtro vigencia_inicio <= @fim respeita o CHECK (fim >= inicio).
UPDATE consultor_unidade
   SET vigencia_fim = @fim
 WHERE consultor_id = @c
   AND unidade_id   = @u_de
   AND vigencia_inicio <= @fim
   AND (vigencia_fim IS NULL OR vigencia_fim > @fim);

-- 1b) Abre o vínculo da BYD Ceasa a partir de @mes (INSERT IGNORE => não duplica).
INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT @c, @u_para, @mes, NULL FROM DUAL
 WHERE @c IS NOT NULL AND @u_para IS NOT NULL;

-- 1c) Garante que esse vínculo esteja VIGENTE (caso a linha já existisse fechada).
UPDATE consultor_unidade
   SET vigencia_fim = NULL
 WHERE consultor_id = @c AND unidade_id = @u_para AND vigencia_inicio = @mes;

-- 1d) Coluna legada, se existir.
SET @sql := IF(@tem_uid > 0,
  'UPDATE IGNORE consultores SET unidade_id = @u_para WHERE id = @c',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- =============================================================================
-- 2) CIBELE CAVALCANTE — BYD Aricanduva -> BYD Vila Guilherme
-- =============================================================================
SET @u_de   := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Aricanduva');
SET @u_para := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Vila Guilherme');

SET @c := (
  SELECT cu.consultor_id
  FROM consultor_unidade cu
  JOIN consultores c ON c.id = cu.consultor_id
  WHERE c.nome = 'Cibele Cavalcante' AND cu.unidade_id = @u_de
  ORDER BY (cu.vigencia_fim IS NULL) DESC, cu.vigencia_inicio DESC
  LIMIT 1
);
SET @c := IF(@c IS NULL
             AND (SELECT COUNT(*) FROM consultores WHERE nome = 'Cibele Cavalcante') = 1,
             (SELECT id FROM consultores WHERE nome = 'Cibele Cavalcante'),
             @c);

SELECT IF(@c IS NULL OR @u_para IS NULL,
          'ERRO: confira o nome exato da consultora / a unidade BYD Vila Guilherme. Nada foi alterado no item 2.',
          CONCAT('OK item 2: consultor id=', @c, ' -> unidade id=', @u_para)) AS status_cibele;

-- 2a) Fecha o vínculo da BYD Aricanduva.
--     OBS: os vínculos BYD começaram em 2026-07-01. Se @mes for 2026-07-01,
--     @fim cairia ANTES do início e esta linha (propositalmente) não faz nada —
--     nesse caso a troca é "sempre foi Vila Guilherme": veja a nota no fim.
UPDATE consultor_unidade
   SET vigencia_fim = @fim
 WHERE consultor_id = @c
   AND unidade_id   = @u_de
   AND vigencia_inicio <= @fim
   AND (vigencia_fim IS NULL OR vigencia_fim > @fim);

-- 2b) Abre o vínculo da BYD Vila Guilherme a partir de @mes.
INSERT IGNORE INTO consultor_unidade (consultor_id, unidade_id, vigencia_inicio, vigencia_fim)
SELECT @c, @u_para, @mes, NULL FROM DUAL
 WHERE @c IS NOT NULL AND @u_para IS NOT NULL;

-- 2c) Garante vigente.
UPDATE consultor_unidade
   SET vigencia_fim = NULL
 WHERE consultor_id = @c AND unidade_id = @u_para AND vigencia_inicio = @mes;

-- 2d) Coluna legada, se existir.
SET @sql := IF(@tem_uid > 0,
  'UPDATE IGNORE consultores SET unidade_id = @u_para WHERE id = @c',
  'SELECT 1');
PREPARE _s FROM @sql; EXECUTE _s; DEALLOCATE PREPARE _s;

-- =============================================================================
-- 3) GERENTE DA FIAT NAÇÕES UNIDAS — Adriano -> Alexandre
--    O gerente é uma coluna da unidade (unidades.gerente) e a view só lê dela:
--    1 UPDATE resolve, sem tocar em lançamento, consultor ou vínculo.
--    O LIKE cobre as duas grafias em uso ("Nações Unidas" / "Nações Unidadas").
-- =============================================================================
UPDATE unidades
   SET gerente = 'Alexandre'
 WHERE marca = 'Fiat'
   AND loja LIKE 'Na%es Unida%';

COMMIT;

-- =============================================================================
-- CONFERÊNCIA (rodam depois; não alteram nada)
--
-- Esperado no 1º SELECT — 2 linhas VIGENTES (BYD Ceasa e BYD Vila Guilherme) e
-- as antigas encerradas em 2026-07-01. Se aparecerem DUAS linhas vigentes para a
-- mesma pessoa, o fechamento não pegou (vigência começava depois de @fim):
-- feche a antiga na mão com o id que aparecer aqui.
-- =============================================================================
SELECT c.nome AS consultor, u.nome_exibicao AS unidade,
       cu.vigencia_inicio, cu.vigencia_fim,
       IF(cu.vigencia_fim IS NULL, 'VIGENTE', 'encerrado') AS situacao
FROM consultor_unidade cu
JOIN consultores c ON c.id = cu.consultor_id
JOIN unidades    u ON u.id = cu.unidade_id
WHERE c.nome IN ('Ivan Oliveira dos Santos', 'Cibele Cavalcante')
ORDER BY c.nome, cu.vigencia_inicio;

-- Esperado: Fiat Nações Unida(da)s -> Alexandre.
SELECT id, marca, loja, nome_exibicao, gerente
FROM unidades
WHERE marca = 'Fiat'
ORDER BY loja;
