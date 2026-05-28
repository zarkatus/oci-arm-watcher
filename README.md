# oci-arm-watcher

Watcher que provisiona uma VM `VM.Standard.A1.Flex` (Ampere ARM, Always Free) na
tenancy Oracle assim que houver capacity em `sa-saopaulo-1`.

Motivo: a região São Paulo só tem 1 AD e frequentemente retorna
`Out of host capacity` para o shape ARM gratuito. Este repo roda um cron a cada
5 minutos tentando criar a instância `mailcow-ces`; em cada execução tenta
4 OCPU/24 GB, depois 2/12, depois 1/6.

Quando consegue, grava `VM_CREATED.json` (IP público + OCID) e abre um issue.
Execuções seguintes detectam o marcador e param.

Credenciais OCI ficam em GitHub Secrets (`OCI_CLI_*`). A chave SSH pública
`mailcow_ces.pub` é injetada na VM; a privada correspondente vive apenas no
Cloud Shell do dono.
