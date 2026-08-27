# Segurança do runner-mgr

Este repositório opera runners self-hosted do GitHub Actions. Um runner
self-hosted executa código de terceiros por definição: qualquer PR, qualquer
dependência nova, qualquer action de marketplace. Este documento descreve o que
o código defende, o que ele **não** defende, e o que precisa ser feito fora dele.

## Modelo de ameaça

O repositório alvo (`GITHUB_REPO`) é **público**. Isso significa que um PR de
fork, aberto por qualquer pessoa na internet, pode executar código nesta
máquina. A própria documentação do GitHub desaconselha self-hosted runners em
repositórios públicos exatamente por isso.

O adversário assumido, portanto, é: **código arbitrário rodando dentro de um job
de CI, nesta máquina, com o mesmo usuário que roda o `runner-mgr`.**

Isso não é hipotético — é o modo normal de operação. O workdir do job é
`runners/runner-N/_work`, um nível abaixo do `.env`.

## O que foi corrigido

Auditoria de 27/08/2026, commit `f1f97ed`. Cada item tem teste em
`tests/security-checks.sh`.

| Área | O que era possível | Defesa |
|---|---|---|
| Injeção de comando | Um diretório chamado `runner-9';comando;#` em `runners/` fazia o watchdog executar `comando` a cada 15s | `require_runner_id` valida todo ID; o `run.sh` é invocado sem montar string de shell |
| Roubo do PAT | `grep Bearer /proc/*/cmdline` capturava o token com escopo `repo` | Token vai por `curl --config -` no stdin, nunca no argv |
| Execução via cache | Um job trocava o tarball em `cache/` e o próximo `up` executava o binário do atacante | SHA256 conferido contra a release, inclusive no cache hit |
| `rm -rf` fora de escopo | `down '1/../../vitima'` apagava fora de `runners/` | `safe_rm_runner_dir` reconfere o caminho resolvido |
| Execução via `.env` | Um `$(...)` em qualquer valor rodava como nós | `.env` é parseado como dado, com allowlist de chaves |
| Contaminação entre jobs | O que um job deixava plantado atendia o próximo | `RUNNER_EPHEMERAL=1` + limpeza do `_work` |
| PID reciclado | `stop` mandava SIGKILL para o grupo de um processo alheio | Identidade confirmada pelo cwd em `/proc` |
| Falha de API silenciosa | 401/403/rate limit virava `[]`, e decisões destrutivas rodavam em cima disso | `gh_curl` checa status e propaga erro |

## O que NÃO está corrigido

**O job de CI continua rodando com o mesmo usuário que o gerenciador.** Nenhuma
das mudanças acima altera isso, e é o risco dominante. Enquanto for verdade, um
job malicioso consegue:

- ler o `.env` e extrair o PAT — o `chmod 600` não protege contra o próprio dono;
- ler `/proc` dos nossos processos;
- escrever em `runners/`, `cache/`, `state/` e `logs/`;
- criar unidades systemd `--user`, que com `linger` habilitado sobrevivem a reboot.

O `--ephemeral` reduz a *persistência* (o runner não carrega estado de um job
para o próximo), mas não impede nada durante a janela em que o job roda.

Duas exposições menores também permanecem, por limitação da ferramenta:

- O registration token vai no argv do `config.sh` — o runner do GitHub não aceita
  o token por outro meio. É de vida curta e single-use, mas quem o capturar pode
  registrar um runner rogue e passar a receber jobs.
- Os alertas do queue monitor vão, por padrão, para o `ntfy.sh` público, onde o
  tópico é o único segredo.

## O que fazer, em ordem de retorno

1. **Exigir aprovação para PRs de fork.** No repositório alvo:
   Settings → Actions → General → "Fork pull request workflows from outside
   collaborators" → **Require approval for all outside collaborators**. O padrão
   de repositório público ("first-time contributors") não basta: uma conta com
   um PR trivial já aceito passa a rodar código sem revisão. Esta é a mudança
   de maior efeito e a mais barata — e é a única desta lista que fecha o vetor
   de entrada em vez de limitar o estrago.

2. **Usuário dedicado para os runners.** Criar um usuário sem acesso ao
   diretório do `runner-mgr`, e rodar os runners como ele. É o único item que
   fecha a leitura do `.env`. Custa uma mudança no modelo de deploy.

3. **PAT fine-grained com o mínimo.** Em vez de um PAT clássico com escopo
   `repo`, um fine-grained com apenas *Administration: read/write* no
   repositório alvo. Não impede o roubo, mas reduz o que o token roubado faz.

4. **ntfy self-hosted, ou tópico com ACL e `NTFY_TOKEN`.**

5. **Sandbox por job.** Executar o runner dentro de um serviço transiente do
   systemd (`systemd-run --user` sem `--scope`) permite `InaccessiblePaths=`,
   `ReadOnlyPaths=` e `NoNewPrivileges=` — o que tornaria o `.env` invisível
   para o job mesmo com o mesmo UID. Não foi feito aqui porque troca o modelo de
   rastreamento de processo (o PID deixa de ser nosso filho e passa a vir do
   `MainPID` da unidade), e esse caminho já custou vários incidentes neste
   repositório. Vale como próximo passo, com tempo para testar.

## Sinais de comprometimento

`runner-mgr status`, `runner-mgr clean` e o watchdog reportam diretórios em
`runners/` fora do padrão `runner-<número>`. Eles nunca são usados como ID, mas
a presença deles é suspeita: nada no fluxo normal cria um. Se aparecerem sem que
você tenha criado, trate como indício e investigue os logs dos jobs recentes.

## Rodando as verificações

```sh
./tests/security-checks.sh    # não precisa de token, rede ou systemd
shellcheck -s bash -x runner-mgr lib/*.sh tests/*.sh
```
