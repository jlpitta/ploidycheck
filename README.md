# ploidycheck

Chama heterozigose/poliploidia de um organismo a partir de short reads, usando só o perfil de k-mer (sem montagem, sem genoma de referência). Extraído do módulo de poliploidia originalmente construído dentro do [fungiflow](https://github.com/jlpitta/fungiflow), agora como ferramenta standalone reutilizável por qualquer pipeline — incluindo o [fungiflow](https://github.com/jlpitta/fungiflow) e o [checkw](https://github.com/jlpitta/checkw), que passam a chamá-la como dependência externa em vez de reimplementar a lógica.

## Por que isso existe

Ferramentas de avaliação de qualidade genômica desenhadas para bactéria (ex. CheckM2) assumem genoma haploide. Quando aplicadas a um organismo heterozigoto/poliploide, variantes alélicas de um mesmo gene em cópias divergentes são facilmente confundidas com contaminação (múltiplas cópias "quase idênticas" de um gene que deveria ser único). Antes de decidir se uma amostra é ou não contaminada, ajuda saber se ela é poliploide/heterozigota — essa é a única pergunta que o `ploidycheck` responde.

Ele não monta o genoma nem faz nenhuma inferência taxonômica: só olha a distribuição de frequência de k-mers nos reads e decide, com um critério validado empiricamente, se há sinal de heterozigose.

## Como funciona

Pipeline de 4 passos, cada um delegado a uma ferramenta estabelecida:

```
short reads (R1/R2)
   │
   ▼
FastK + Histex   → histograma de frequência de k-mers (k=21 por padrão)
   │
   ├─────────────────────────┐
   ▼                          ▼
GenomeScope2               Smudgeplot
(heterozigose global,      (estrutura de ploidia via pares
 kmercov)                   de k-mers heterozigóticos — AB,
   │                         AAB, AABB, ...)
   │                          │
   └────────────┬─────────────┘
                ▼
        ploidy_call.py
   (combina os dois sinais num veredito único)
                │
                ▼
   <sample>.ploidy_call.json
```

### O critério de decisão — e por que ele existe

Nenhuma das duas ferramentas é confiável sozinha na faixa de cobertura de k-mer tipicamente baixa (~11-12x) dos datasets de validação usados aqui:

- O cutoff `-L` que o próprio `smudgeplot cutoff` sugere automaticamente (~10, nesses datasets) infla a cobertura 1n inferida em quase 2x em relação ao `kmercov` real do GenomeScope2, mantendo uma smudge AB enganosamente "limpa" — ou seja, o valor sugerido pela ferramenta gera um falso positivo mais convincente, não menos.
- Valores de `-L` mais baixos recuperam o sinal corretamente. `-L 7` foi o que deu resultado mais limpo nos testes e é o default aqui (configurável via `--smudge-l`).

Por isso, heterozigose só é chamada como real quando **dois sinais concordam simultaneamente**:

1. A smudge `AB` é maioria da massa detectada pelo Smudgeplot (≥ `--ab-fraction-threshold`, default 0.5).
2. A cobertura 1n que o Smudgeplot infere bate com o `kmercov` do GenomeScope2 dentro de uma tolerância relativa (`--coverage-tolerance`, default 0.3 = 30%).

Isso foi validado contra dois datasets sintéticos de *Saccharomyces cerevisiae* (haploide e heterozigótico com 1.5% de divergência entre haplótipos — ver [Validação](#validação) abaixo), e é a única combinação que deu a resposta certa nos dois casos ao mesmo tempo.

## Instalação

```bash
git clone https://github.com/jlpitta/ploidycheck.git
cd ploidycheck
./install.sh
```

O `install.sh`:
- Detecta `mamba`/`micromamba`/`conda` no PATH. **Se nenhum for encontrado, baixa e instala o Miniforge3 automaticamente** (modo silencioso, `-b -p ~/miniforge3`) e segue a instalação sem precisar de passo manual.
- Cria o ambiente `ploidycheck` (env dedicado, não compartilhado com bacflow/fungiflow/checkw) a partir de `envs/ploidycheck.yaml`: `kmc`, `genomescope2`, `fastk`, `smudgeplot`.
- Aplica um patch necessário no Smudgeplot (ver [Nota técnica](#nota-técnica--patch-do-smudgeplot) abaixo) de forma idempotente — roda de novo sem duplicar o patch se o ambiente já estiver corrigido.

## Uso

```bash
./ploidycheck \
  --sample minha_amostra \
  --r1 reads_R1.fastq.gz \
  --r2 reads_R2.fastq.gz \
  --outdir results/minha_amostra
```

### Opções

| Flag | Default | Descrição |
|---|---|---|
| `--sample` | *(obrigatório)* | Nome/prefixo da amostra |
| `--r1` | *(obrigatório)* | Short reads R1 (fastq/fastq.gz) |
| `--r2` | *(obrigatório)* | Short reads R2 (fastq/fastq.gz) |
| `--outdir` | *(obrigatório)* | Diretório de saída (criado se não existir) |
| `--threads` | 4 | Threads para FastK/Smudgeplot |
| `--kmer-size` | 21 | Tamanho do k-mer |
| `--smudge-l` | 7 | Cutoff `-L` do Smudgeplot — ver [seção acima](#o-critério-de-decisão--e-por-que-ele-existe) |
| `--ab-fraction-threshold` | 0.5 | Fração mínima da smudge AB para considerar dominante |
| `--coverage-tolerance` | 0.3 | Tolerância relativa entre `kmercov` e cobertura 1n inferida |
| `--env` | `ploidycheck` | Nome do ambiente conda/mamba a usar |

### Saída

Em `--outdir`:

- **`<sample>.ploidy_call.json`** — resultado final, schema:

```json
{
  "sample": "minha_amostra",
  "genomescope_kmercov": 11.71,
  "smudgeplot_haploid_coverage": 11.0,
  "smudgeplot_ab_fraction": 0.756,
  "coverage_relative_error": 0.061,
  "ab_fraction_threshold": 0.5,
  "coverage_tolerance": 0.3,
  "ab_dominant": true,
  "coverage_agrees": true,
  "heterozygous_detected": true
}
```

- `<sample>.histo` — histograma de k-mer (Histex, formato compatível com GenomeScope2)
- `gs2_out/` — saída completa do GenomeScope2 (modelo, plots)
- `<sample>_smudgeplot_report.json` + PNGs — saída completa do Smudgeplot

O único campo que a maioria dos consumidores precisa é `heterozygous_detected` — os demais existem pra auditoria/debug do critério.

## Validação

Testado nos dois datasets sintéticos de *S. cerevisiae* do fungiflow (`genome_test/saccharomyces_cerevisiae_synthetic` e `genome_test/saccharomyces_cerevisiae_heterozygous`, ~30x short reads via wgsim):

| Dataset | genomescope_kmercov | AB fraction | cobertura 1n (Smudgeplot) | `heterozygous_detected` | Esperado |
|---|---|---|---|---|---|
| haploide (`scerevisiae_test`) | 11.71 | 43.7% | 11.0 | `false` | `false` ✅ |
| heterozigótico 1.5% (`scerevisiae_het_test`) | 11.67 | 75.6% | 11.0 | `true` | `true` ✅ |

No dataset haploide, a smudge AB aparece mas fica bem abaixo do threshold de dominância (43.7% < 50%) — é ruído esperado (rDNA multi-cópia, elementos Ty, genes subteloméricos duplicados em *S. cerevisiae*), não heterozigose real. É exatamente esse ruído que o critério combinado existe pra filtrar.

## Nota técnica — patch do Smudgeplot

O Smudgeplot 0.5.3 (bioconda) quebra com pandas ≥3.0 (`AttributeError: Can only use .str accessor with string values`), bug reportado e ainda aberto no [upstream (issue #255)](https://github.com/KamilSJaron/smudgeplot/issues/255). `patches/smudgeplot_pandas3_fix.patch` corrige dois pontos:

1. Força a coluna `structure` para `str` logo após a construção do DataFrame de smudges — corrige o crash quando zero smudges são detectados.
2. Normaliza o dicionário de smudges (mistura de listas e placeholders NaN escalares) antes do `DataFrame.from_dict` — a correção sugerida no issue upstream (`orient='index'`) regride nesse caso; essa versão do fix é própria, não do issue.

O `install.sh` aplica esse patch automaticamente e de forma idempotente.

## Origem e projetos relacionados

Construído originalmente como parte do plano de tratamento de poliploidia do [fungiflow](https://github.com/jlpitta/fungiflow) (fork do [bacflow](https://github.com/jlpitta/bacflow) para genomas de fungo), extraído para repositório próprio para ser reutilizável também pelo [checkw](https://github.com/jlpitta/checkw) (ferramenta de detecção de contaminação genômica reference-free) — lá, o `heterozygous_detected` serve como contexto para relaxar o sinal de redundância gênica em organismos eucarióticos heterozigotos/poliploides, evitando que variantes alélicas sejam confundidas com contaminação.

---

by João Pitta and Beatriz Toscano — Fiocruz-PE
