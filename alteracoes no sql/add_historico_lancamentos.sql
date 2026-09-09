-- =============================================================================
--  Migração: HISTÓRICO DE LANÇAMENTOS (lancamentos_historico)
--  Banco: dashboard_dahruj  (MySQL 8.0+)
--
--  CONTEXTO
--    A tabela `lancamentos` tem UNIQUE (consultor_id, mes, unidade_id) e o app
--    grava com ON DUPLICATE KEY UPDATE. Isso é o comportamento CORRETO para o
--    dashboard — o valor do mês é sempre o acumulado mais recente —, mas apaga o
--    rastro: quando o gerente lança a 2ª semana, o valor da 1ª desaparece e não
--    dá mais para saber quanto foi vendido em CADA semana.
--
--  O QUE ESTA MIGRAÇÃO FAZ (idempotente — pode rodar quantas vezes quiser)
--    1) Cria `lancamentos_historico`: tabela append-only, um registro por evento
--       (cada "Salvar lançamento" e cada exclusão da tela de Lançamento).
--    2) Cria a view `vw_lancamentos_historico`, que calcula NA LEITURA o número
--       do lançamento dentro do mês e a DIFERENÇA para o lançamento anterior —
--       ou seja, o quanto foi vendido naquele período/semana.
--    3) BACKFILL: copia os lançamentos que já existem hoje para o histórico,
--       como o lançamento nº 1 de cada mês.
--
--    NÃO altera `lancamentos` nem `vw_base_tidy`. O dashboard continua idêntico.
--
--  COMO RODAR
--    Recomendado (aplica nos dois bancos e faz commit explícito — no Aiven o
--    autocommit vem desligado e o SQL colado na mão fica pendente):
--        python aplicar_migracao_historico.py
--        python aplicar_migracao_historico.py --destino local
--        python aplicar_migracao_historico.py --destino online
--
--    Na mão, se preferir: faça backup antes
--        mysqldump -u root -p dashboard_dahruj > backup.sql
--    e cole TUDO de uma vez no console MySQL, conferindo o COMMIT no final.
-- =============================================================================

USE dashboard_dahruj;

-- -----------------------------------------------------------------------------
-- 1) lancamentos_historico  (TABELA DE EVENTOS — append-only)
--
--    Uma linha por EVENTO, nunca atualizada e nunca apagada pelo app.
--
--    `passagens`/`refil_*` guardam o ESTADO APÓS o evento: no salvamento, os
--    valores gravados (que são o acumulado do mês); na exclusão, zeros — assim a
--    diferença do evento de exclusão é negativa e zera o acumulado, e o próximo
--    lançamento volta a contar do zero. As diferenças sempre somam o acumulado.
--
--    SEM FOREIGN KEY de propósito: a FK de `lancamentos` para `consultores` é
--    ON DELETE CASCADE, e o histórico não pode ser levado junto se um consultor
--    for removido do cadastro. Pelo mesmo motivo guardamos os NOMES por snapshot
--    (consultor_nome/unidade_nome/marca): a exportação continua legível mesmo
--    depois de renomeação, transferência ou exclusão de cadastro.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lancamentos_historico (
  id             BIGINT    NOT NULL AUTO_INCREMENT,
  consultor_id   INT       NOT NULL,
  unidade_id     INT       NOT NULL,
  mes            DATE      NOT NULL,
  tipo           ENUM('lancamento','exclusao') NOT NULL DEFAULT 'lancamento',
  -- Estado APÓS o evento (na exclusão, zeros).
  passagens      INT       NULL,
  refil_diant    INT       NOT NULL DEFAULT 0,
  refil_tras     INT       NOT NULL DEFAULT 0,
  -- Snapshot do cadastro no momento do evento.
  consultor_nome VARCHAR(120) NULL,
  unidade_nome   VARCHAR(120) NULL,
  marca          VARCHAR(50)  NULL,
  -- 'app' = tela de Lançamento; 'backfill' = carga inicial desta migração.
  origem         VARCHAR(20) NOT NULL DEFAULT 'app',
  registrado_em  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_hist_chave (consultor_id, unidade_id, mes, registrado_em),
  KEY idx_hist_mes (mes)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- 2) VIEW vw_lancamentos_historico
--    O que a página "Histórico" do app lê e exporta. Tudo é calculado na
--    leitura, então nada no banco fica desatualizado.
--
--    - n_lancamento      : número do lançamento DENTRO do mês, por consultor e
--                          unidade. Conta só os eventos 'lancamento' (a soma
--                          corrente de tipo='lancamento'), então "nº 3" é sempre
--                          o 3º lançamento de verdade. Um evento de exclusão
--                          repete o número do lançamento que ele cancelou — a
--                          coluna `tipo` desambigua.
--    - *_periodo         : diferença para o evento anterior = o que foi vendido
--                          NAQUELE período (a "semana"). LAG(..., 1, 0) faz o
--                          primeiro evento do mês valer ele mesmo por inteiro.
--    - total_geral       : faturamento acumulado no mês até aquele evento.
--    - total_periodo     : faturamento DAQUELE período (é o que interessa para a
--                          análise semanal). Mesma fórmula de vw_base_tidy.
--
--    A cláusula OVER (...) é repetida inline em cada coluna, em vez de uma
--    WINDOW nomeada, por compatibilidade dentro de CREATE VIEW.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_lancamentos_historico AS
SELECT
  h.id                                       AS evento_id,
  -- CAST porque SUM() devolve DECIMAL: sem ele o número do lançamento chega no
  -- Python como Decimal e quebra as comparações/pivots do relatório.
  CAST(SUM(h.tipo = 'lancamento') OVER (
    PARTITION BY h.consultor_id, h.unidade_id, h.mes
    ORDER BY h.registrado_em, h.id
    ROWS UNBOUNDED PRECEDING) AS SIGNED)     AS n_lancamento,
  h.tipo                                     AS tipo,
  h.registrado_em                            AS registrado_em,
  h.origem                                   AS origem,
  h.consultor_id                             AS consultor_id,
  h.consultor_nome                           AS consultor,
  h.unidade_id                               AS unidade_id,
  h.unidade_nome                             AS unidade,
  h.marca                                    AS marca,
  h.mes                                      AS mes,
  DATE_FORMAT(h.mes, '%m/%Y')                AS mes_label,

  -- Acumulado no mês até este evento (o que estava gravado em `lancamentos`).
  h.passagens                                AS passagens,
  h.refil_diant                              AS refil_diant,
  h.refil_tras                               AS refil_tras,
  CASE WHEN h.passagens > 0
       THEN ROUND(h.refil_diant / h.passagens, 4)
       ELSE NULL
  END                                        AS aproveitamento,
  ROUND(h.refil_diant * p.preco_diant
      + h.refil_tras  * p.preco_tras, 2)     AS total_geral,

  -- Diferença para o evento anterior = venda do período (a "semana").
  COALESCE(h.passagens, 0) - LAG(COALESCE(h.passagens, 0), 1, 0) OVER (
    PARTITION BY h.consultor_id, h.unidade_id, h.mes
    ORDER BY h.registrado_em, h.id)          AS passagens_periodo,
  h.refil_diant - LAG(h.refil_diant, 1, 0) OVER (
    PARTITION BY h.consultor_id, h.unidade_id, h.mes
    ORDER BY h.registrado_em, h.id)          AS refil_diant_periodo,
  h.refil_tras - LAG(h.refil_tras, 1, 0) OVER (
    PARTITION BY h.consultor_id, h.unidade_id, h.mes
    ORDER BY h.registrado_em, h.id)          AS refil_tras_periodo,
  ROUND(
    (h.refil_diant - LAG(h.refil_diant, 1, 0) OVER (
       PARTITION BY h.consultor_id, h.unidade_id, h.mes
       ORDER BY h.registrado_em, h.id)) * p.preco_diant
  + (h.refil_tras - LAG(h.refil_tras, 1, 0) OVER (
       PARTITION BY h.consultor_id, h.unidade_id, h.mes
       ORDER BY h.registrado_em, h.id)) * p.preco_tras
  , 2)                                       AS total_periodo
FROM lancamentos_historico h
-- LEFT JOIN: se a marca do snapshot sumir de precos_marca, a linha do histórico
-- continua aparecendo (sem faturamento) em vez de desaparecer do relatório.
LEFT JOIN precos_marca p ON p.marca = h.marca;

-- -----------------------------------------------------------------------------
-- 3) BACKFILL — os lançamentos que já existem viram o nº 1 do seu mês.
--
--    Idempotente pelo NOT EXISTS: rodar de novo não duplica nada, porque só
--    insere para (consultor, unidade, mês) que ainda não tem NENHUMA linha no
--    histórico. Em consequência, um mês que já tenha histórico nunca é tocado.
--
--    Usa updated_at (com fallback para created_at) porque os valores copiados
--    são o ESTADO ATUAL da linha — o timestamp precisa bater com eles, não com o
--    momento em que o mês foi lançado pela primeira vez.
-- -----------------------------------------------------------------------------
INSERT INTO lancamentos_historico
  (consultor_id, unidade_id, mes, tipo, passagens, refil_diant, refil_tras,
   consultor_nome, unidade_nome, marca, origem, registrado_em)
SELECT
  l.consultor_id, l.unidade_id, l.mes, 'lancamento',
  l.passagens, l.refil_diant, l.refil_tras,
  c.nome, u.nome_exibicao, u.marca, 'backfill',
  COALESCE(l.updated_at, l.created_at)
FROM lancamentos l
JOIN consultores c ON c.id = l.consultor_id
JOIN unidades    u ON u.id = l.unidade_id
WHERE NOT EXISTS (
  SELECT 1 FROM lancamentos_historico h
  WHERE h.consultor_id = l.consultor_id
    AND h.unidade_id   = l.unidade_id
    AND h.mes          = l.mes
);
