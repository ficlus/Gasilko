# GASILKO — V2 FULL IMPLEMENTATION SPECIFICATIONS

**Datum:** 28. oktober 2026  
**Repo:** https://github.com/ficlus/Gasilko  
**Paket:** 34 samostojnih podrobnih angleških promptov za Codex, skupaj z načrtom, pravili vrstnega reda in čakalno vrsto Work.

## Kaj je drugače od V1

Prva izdaja je bila prekratka za neposredno izvedbo kompleksnih milestoneov (približno 1.300 besed na nalogo). V2 ima okoli **4.200–4.600 besed na nalogo** in vključuje:

- konkretne integracijske točke in obstoječe domenske sisteme za ponovno uporabo;
- poseben predlog podatkovnega modela za vsak milestone (predlog, ne trditev, da ta schema že obstaja);
- opis algoritma in dejanskega podatkovnega toka;
- dovoljenja, actor/org/incident scope, RLS in privacy meje;
- receipt/UUID, zaklepe, verzioniranje in izgubljene odgovore;
- specifične robne primere in ročne prevzemne primere;
- Android/Web/Room/MapLibre/M10/SIM učinke, kjer so pomembni;
- omejitve, dokumentiranje, postopek namestitve in striktna pravila Codexa;
- prvotni V1 prompt na dnu kot zgodovinsko referenco, da nič ne izpustimo.

Skupne varnostne in implementacijske zahteve so namerno ponovljene, da je **vsak** prompt samostojen. V2 ni trditev, da bodo vse predlagane sheme veljavne brez pregleda trenutne kode.

## Uporaba

1. Preberi `01_V2_PROMPT_INDEX.md` in `02_GATES_AND_SEQUENCE.md`.
2. Za posamezno nalogo odpri **en** `prompts/*.md` in ga podaj Codexu šele po izrecni odobritvi, ko so odvisnosti izpolnjene.
3. Work naj uporabi `automation/queue.json`, vendar ima celoten paket `approved_by_owner=false`. Naloge ne smejo same steči zaradi tega ZIP-a.
4. Worku dodaj `automation/V2_WORK_COORDINATOR_START.md` za načrtovanje/PR preglede. Dejanska možnost avtomatskega pošiljanja Codexu in kvota se morata preveriti s pravimi orodji.
5. Po PR-ju agent opravi pregled **dejanske trenutne kode**; do dva kroga popravkov v istem PR-ju; samo ti odločaš o merge-u.
6. SQL migracije, Edge/Web/Android deploy ter ročno preverjanje opraviš ti. Git pull prenese datoteke, ne uporabi SQL.
7. Paket dodaj v ChatGPT Project `Gasilko — Development & Architecture` kot Markdown vire, ne zgolj ZIP.

## Pomembno stanje ob pripravi

- GitHub PR **#82** je ob zadnjem javnem preverjanju **OPEN**, zato ima prompt `00` poseben režim **popravljanja istega PR-ja**, nikakor novega. Pregled SQL dollar-quote napake je zgodovinski: pred uporabo preveri najnovejši HEAD, ker jo Codex morda že popravlja.
- Prejšnji milestonei M14.6 in #74–#81 so glede kode predhodni. GitHub `MERGED` ni dokaz, da je tvoja Supabase baza posodobljena ali Android APK zgrajen.
- Pilot: prijavljeni pravi uporabniki, ročno ustvarjena **TRAINING** intervencija, Web poveljnik + Android vodja enote + gasilec. To še ni izdaja za dejansko operativno uporabo.
- `AGENTS.md` na GitHubu je obvezen in ga ne prepiši z našim dokumentom; morebitno nasprotje glede izvajanja testov naj Codex javno zabeleži. Po tvojem trenutnem pravilu Codex dela **samo implementacijo**, brez testov/builda/CI/SQL/deploya.
- REAL GPS, CAD/112, UAS/droni, AR in podobno potrebujejo ločeno odobritev. Niso odobreni samo z nastankom prompta.

## Struktura

- `prompts/` — **34** posamičnih angleških izvedbenih promptov.
- `01_V2_PROMPT_INDEX.md` — kazalo in dolžina vsakega prompta.
- `02_GATES_AND_SEQUENCE.md` — zaporedje, merge/approval/dependency gates.
- `03_V2_QUALITY_AND_SOURCE_NOTES.md` — kakovost, meje in reference.
- `automation/queue.json` — pripravljena, **neodobrena** čakalna vrsta za Work.
- `automation/V2_WORK_COORDINATOR_START.md` — navodila Worku.
- `reference/` — zgodovinski izsek projektnega konteksta, ni živa koda.
- `04_HUMAN_ROLLOUT_CHECKLIST.md`, `05_SOURCE_EVIDENCE_AND_STATUS.md` — človeški postopki / stanje.

## Source-of-truth in uporaba v prihodnje

1. Trenutni GitHub `main`, odprti PR HEAD, shema in funkcije v kodi.
2. Trenutni `docs/SPEC.md`, `docs/SPEC-M14-INCIDENT-OPERATIONS.md`, `AGENTS.md`.
3. Novejše lastnikove odločitve in rezultati ročnega preizkusa.
4. Ta V2 paket in zgodovinska V1 dokumentacija.

**Vsak prompt je tehnično naročilo za Codex, ne avtomatsko dovoljenje ali jamstvo za združljivost s prihodnjo verzijo repozitorija.**
