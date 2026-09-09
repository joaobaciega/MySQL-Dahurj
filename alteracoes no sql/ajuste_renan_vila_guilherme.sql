-- =============================================================================
--  Ajuste manual: lançamento do Renan na BYD Vila Guilherme (unidade ANTIGA)
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  POR QUE NO SQL E NÃO PELO APP
--    A tela de Lançamento lista só a lotação VIGENTE de cada unidade
--    (consultor_unidade com vigencia_fim IS NULL). Como o Renan foi transferido
--    para a BYD Ceasa, ele sumiu da lista da Vila Guilherme e nenhum mês dele
--    pode mais ser editado por lá pelo app.
--
--  O QUE FAZ
--    Deixa a linha (Renan, BYD Vila Guilherme, mês-alvo) com:
--        passagens = 62 | refil_diant = 25 | refil_tras = 22
--    São valores ABSOLUTOS (= 40+22, 17+8, 14+8). Rodar duas vezes não soma de
--    novo — o resultado é sempre 62/25/22.
--    Nada de vínculo/vigência é tocado: o Renan continua vigente na BYD Ceasa.
--
--  COMO RODAR
--    Cole TUDO de uma vez no console MySQL online. O primeiro SELECT mostra os
--    lançamentos atuais dele — confira o 40/17/14 ali antes de olhar o resto.
-- =============================================================================

USE dashboard_dahruj;

SET NAMES utf8mb4;
SET autocommit = 1;

-- -----------------------------------------------------------------------------
-- Alvo: unidade antiga + a pessoa (achada pelo vínculo com a Vila Guilherme,
-- mesmo já encerrado; se o vínculo não existir, pelo próprio lançamento).
-- -----------------------------------------------------------------------------
SET @u := (SELECT id FROM unidades WHERE nome_exibicao = 'BYD Vila Guilherme');

SET @c := (
  SELECT cu.consultor_id
  FROM consultor_unidade cu
  JOIN consultores c ON c.id = cu.consultor_id
  WHERE c.nome LIKE 'Renan%' AND cu.unidade_id = @u
  ORDER BY cu.vigencia_inicio DESC
  LIMIT 1
);
SET @c := IFNULL(@c, (
  SELECT l.consultor_id
  FROM lancamentos l
  JOIN consultores c ON c.id = l.consultor_id
  WHERE c.nome LIKE 'Renan%' AND l.unidade_id = @u
  ORDER BY l.mes DESC
  LIMIT 1
));

-- -----------------------------------------------------------------------------
-- DIAGNÓSTICO — todos os lançamentos do Renan, por unidade e mês.
-- É aqui que você identifica a linha 40 / 17 / 14 e o mês dela.
-- -----------------------------------------------------------------------------
SELECT c.nome AS consultor, u.nome_exibicao AS unidade,
       DATE_FORMAT(l.mes, '%m/%Y') AS mes_label, l.mes,
       l.passagens, l.refil_diant, l.refil_tras
FROM lancamentos l
JOIN consultores c ON c.id = l.consultor_id
JOIN unidades    u ON u.id = l.unidade_id
WHERE l.consultor_id = @c
ORDER BY l.mes, u.nome_exibicao;

-- -----------------------------------------------------------------------------
-- MÊS-ALVO
--   Deixe NULL para o script resolver sozinho: só funciona se houver EXATAMENTE
--   UM lançamento do Renan na Vila Guilherme (o caso normal). Se houver mais de
--   um, nada é gravado e a mensagem abaixo manda fixar o mês — troque a linha
--   por:  SET @mes := '2026-07-01';   (ou o mês que aparecer no diagnóstico).
-- -----------------------------------------------------------------------------
-- Fixado em 08/2026: a conferência mostrou DOIS lançamentos dele na Vila
-- Guilherme (07/2026 = 122/30/17, que fica como está, e 08/2026 = 40/17/14, que
-- é a linha a corrigir), então a resolução automática não tinha como escolher.
SET @mes := '2026-08-01';

SET @n := (SELECT COUNT(*) FROM lancamentos WHERE consultor_id = @c AND unidade_id = @u);
SET @mes := IF(@mes IS NOT NULL, @mes,
               IF(@n = 1,
                  (SELECT mes FROM lancamentos WHERE consultor_id = @c AND unidade_id = @u),
                  NULL));

-- Valores atuais da linha-alvo (para o "antes -> depois").
SET @p0 := (SELECT passagens   FROM lancamentos WHERE consultor_id = @c AND unidade_id = @u AND mes = @mes);
SET @d0 := (SELECT refil_diant FROM lancamentos WHERE consultor_id = @c AND unidade_id = @u AND mes = @mes);
SET @t0 := (SELECT refil_tras  FROM lancamentos WHERE consultor_id = @c AND unidade_id = @u AND mes = @mes);
SET @existe := (SELECT COUNT(*) FROM lancamentos WHERE consultor_id = @c AND unidade_id = @u AND mes = @mes);

SELECT CASE
  WHEN @c IS NULL OR @u IS NULL
    THEN 'ERRO: Renan ou a unidade BYD Vila Guilherme nao foram encontrados. Nada foi alterado.'
  WHEN @mes IS NULL
    THEN CONCAT('PARE: ha ', @n, ' lancamento(s) do Renan na BYD Vila Guilherme. ',
                'Escolha o mes no diagnostico acima, troque a linha para ',
                'SET @mes := ''2026-07-01''; e rode de novo. Nada foi alterado.')
  WHEN @existe = 0
    THEN CONCAT('ATENCAO: nao existe linha em ', @mes, ' - uma NOVA sera criada com 62/25/22.')
  ELSE CONCAT('OK: ', @mes, '  antes = ', IFNULL(@p0,'NULL'), ' / ', @d0, ' / ', @t0,
              '   ->   depois = 62 / 25 / 22')
END AS alvo;

-- -----------------------------------------------------------------------------
-- GRAVAÇÃO — UPDATE da linha existente. Tudo guardado por @mes: se o passo
-- anterior disse PARE ou ERRO, estes comandos não atingem nenhuma linha.
-- (UPDATE direto em vez de upsert de propósito: não depende de qual UNIQUE o
--  banco tem hoje, então não há risco de acertar a linha da BYD Ceasa.)
-- -----------------------------------------------------------------------------
UPDATE lancamentos
   SET passagens   = 62,
       refil_diant = 25,
       refil_tras  = 22
 WHERE consultor_id = @c
   AND unidade_id   = @u
   AND mes          = @mes;

-- Só cria linha se realmente não existia nenhuma no mês-alvo.
INSERT INTO lancamentos (consultor_id, unidade_id, mes, passagens, refil_diant, refil_tras)
SELECT @c, @u, @mes, 62, 25, 22 FROM DUAL
 WHERE @existe = 0 AND @c IS NOT NULL AND @u IS NOT NULL AND @mes IS NOT NULL;

COMMIT;

-- =============================================================================
-- CONFERÊNCIA — como o dashboard vai mostrar.
--   Esperado: a linha da BYD Vila Guilherme com 62 / 25 / 22, e a da BYD Ceasa
--   (lotação atual dele) intacta.
-- =============================================================================
SELECT consultor, unidade, mes_label, passagens, refil_diant, refil_tras,
       aproveitamento, total_geral
FROM vw_base_tidy
WHERE consultor_id = @c
ORDER BY mes, unidade;
