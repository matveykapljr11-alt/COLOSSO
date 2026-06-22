# COLOSSO — Backend (Supabase)

Рабочий скелет бэкенда под прототип `colosso_latam.html`. Стек: **Supabase** (PostgreSQL + Auth + Realtime + Storage). Серверного кода почти нет — логика в БД (RLS) и в клиент-слое.

Файлы:
- `schema.sql` — вся схема БД, RLS-политики, триггеры, realtime, storage-бакет.
- `colosso-api.js` — клиент-слой (ES-модуль): авторизация через Discord, CRUD, реалтайм. Каждая функция = одно действие из прототипа.

---

## 1. Создать проект Supabase
1. https://supabase.com → **New project**. Запиши **Project URL** и **anon public key** (Settings → API).

## 2. Применить схему
2. В дашборде: **SQL Editor → New query** → вставь содержимое `schema.sql` → **Run**.
   Создадутся все таблицы, политики безопасности, триггер авто-профиля, realtime и бакет `avatars`.

## 3. Включить вход через Discord
3. На https://discord.com/developers → **New Application** → вкладка **OAuth2**:
   - **Redirect**: `https://<твой-проект>.supabase.co/auth/v1/callback`
   - скопируй **Client ID** и **Client Secret**.
4. В Supabase: **Authentication → Providers → Discord** → вставь Client ID/Secret → **Enable**.
5. **Authentication → URL Configuration** → добавь свой сайт в **Redirect URLs** (напр. `http://localhost:5173`, прод-домен).

## 4. Подключить фронт
В HTML (или сборке) задай ключи и подключи модуль:
```html
<script>
  window.COLOSSO_ENV = {
    SUPABASE_URL: 'https://<твой-проект>.supabase.co',
    SUPABASE_ANON_KEY: '<anon-public-key>'
  };
</script>
<script type="module">
  import { COLOSSO } from './backend/colosso-api.js';
  window.COLOSSO = COLOSSO;        // чтобы вызывать из обработчиков прототипа
</script>
```
> `anon` ключ безопасно держать в браузере — доступ ограничен RLS-политиками.

---

## 5. Как ложатся действия прототипа на API

| Прототип (сейчас на localStorage) | Реальный вызов |
|---|---|
| Вход через Discord | `COLOSSO.auth.signInWithDiscord()` |
| Онбординг (создание профиля) | `COLOSSO.profiles.completeOnboarding({...})` |
| Загрузка аватарки | `COLOSSO.profiles.uploadAvatar(file)` |
| Редактирование профиля | `COLOSSO.profiles.update({...})` |
| Создать команду | `COLOSSO.teams.create({...})` |
| Заявка в команду | `COLOSSO.teams.apply(teamId, msg)` |
| Создать scrim/pracc | `COLOSSO.scrims.create({...})` |
| Отклик/принять scrim → лобби | `COLOSSO.scrims.accept(scrimId)` |
| Veto карт (реалтайм) | `COLOSSO.lobbies.subscribe(id, cb)` + `banMap/ready` |
| Создать турнир | `COLOSSO.tournaments.create({...})` |
| Регистрация команды в турнир | `COLOSSO.tournaments.register(trnId, teamId)` |
| Создать пространство | `COLOSSO.spaces.create({...})` |
| Чат (реалтайм) | `COLOSSO.chat.thread/send/subscribe` |
| Уведомления (реалтайм) | `COLOSSO.notifications.list/subscribe/markAllRead` |
| Быстрый матч | `COLOSSO.matchmaking.findMatch({...})` |

Пример замены (создание скрима):
```js
// было: scrims.unshift({...}); saveState();
const row = await COLOSSO.scrims.create({
  team_id: myTeamId, game: 'free_fire', format: 'Squad (4)',
  server: 'BR · São Paulo', rank: 'Mítico', note: 'Jogo limpo'
});
renderScrims();      // перерисовать из await COLOSSO.scrims.list()
```

Реалтайм-чат:
```js
const ch = COLOSSO.chat.subscribe(convId, (msg) => appendMessage(msg));
await COLOSSO.chat.send(convId, 'bora!');
// при выходе: COLOSSO.sb.removeChannel(ch)
```

---

## 6. Что осталось (по желанию, потом)
- **Edge Functions** для серверной логики matchmaking-очереди и авто-выплат призовых (Pix/Mercado Pago).
- **RPC `lobby_ban_map`** — атомарный бан карты на сервере (черновик вызывается в `lobbies.banMap`; пока можно делать `update bans/decider` на клиенте).
- **Триггеры начисления GLR/XP** после матча (сейчас поля есть, апдейт делает клиент).
- **Сидинг сетки** турнира при старте.

Это уже полноценная основа: реальная авторизация Discord, безопасный доступ через RLS, реалтайм для чата/лобби и хранилище аватарок. Прототип переключается на неё функция за функцией.

---

## 7. Edge Function: авто-перевод чата

Файл: `supabase/functions/translate/index.ts`. Переводит входящие сообщения на язык аккаунта получателя **на сервере**, чтобы не держать ключ перевода в браузере и не упираться в CORS.

Цепочка провайдеров (берётся первый настроенный, последний — бесплатный):
1. `DEEPL_API_KEY` → DeepL (лучшее качество)
2. `GOOGLE_TRANSLATE_API_KEY` → Google Cloud Translation v2
3. без ключей → бесплатный эндпоинт Google `gtx`

Запрос: `POST { "text": "olá, bora treinar", "target": "es" }` → Ответ: `{ "text": "hola, vamos a entrenar", "src": "pt" }`.

### Деплой
Нужен Supabase CLI (`brew install supabase/tap/supabase`), один раз `supabase login`.

```bash
cd backend
supabase link --project-ref zzqlbnjxkuylydwduvzf      # привязать к проекту
supabase functions deploy translate                    # задеплоить функцию
# (опционально, для прод-качества)
supabase secrets set DEEPL_API_KEY=xxxxxxxx
```

Функция требует JWT (по умолчанию), поэтому клиент зовёт её через `sb.functions.invoke('translate', …)` с уже подставленным токеном сессии — открытого доступа извне нет.

### Как это использует фронт
`colosso-api.js` → `COLOSSO.translate.text(text, target)`. В прототипе `translateText()` сначала пробует Edge Function, при ошибке — бесплатный браузерный фолбэк, при полном провале показывает оригинал. То есть деплой функции **повышает** качество/надёжность, но и без него перевод работает.

---

## 8. Начисление GLR / XP после матча

Файл: `glr-xp.sql` (выполнить в SQL Editor после `schema.sql`). Все правила начисления — в одном месте (`_award`), два способа вызвать:

- **RPC `finish_match(p_won, p_lobby)`** — клиент зовёт, когда матч завершён. Победа `+25 GLR / +12 XP`, поражение `-15 GLR / +5 XP`, уровень растёт каждые 100 XP, шлётся уведомление. Возвращает `{glr, xp, level}`.
- **Триггер `trg_lobby_done`** — когда `lobbies.status` становится `done`, автоматически начисляет обеим сторонам (победитель/проигравший по `lobbies.winner_team_id`). «Продакшен-форма», когда исход пишет сервер/судья.

Фронт: `COLOSSO.profiles.finishMatch(true, lobbyId)` вызывается в `readyLobby()` для реального лобби; вернувшиеся `glr/xp/level` сразу обновляют профиль и дашборд.

## 9. Серверная очередь матчмейкинга

Файлы: `matchmaking.sql` (таблица `matchmaking_queue` + RLS + realtime) и `supabase/functions/matchmaking/index.ts`.

Функция работает на **service-role** ключе (минует RLS), чтобы сводить двух разных игроков:
- `join` → ставит тебя в очередь и пытается забрать самого старого ждущего игрока той же игры (race-safe claim), создаёт `scrim` + `lobby`, возвращает `{matched:true, lobby}` либо `{matched:false, status:'waiting'}`.
- `poll` → проверяет, не свёл ли тебя кто-то, пока ты ждал.
- `leave` → убирает из очереди (вызывается при отмене).

### Деплой
```bash
# применить SQL
#   SQL Editor → glr-xp.sql → Run
#   SQL Editor → matchmaking.sql → Run
# задеплоить функции
cd backend
supabase functions deploy matchmaking
```
Встроенные секреты (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`) Supabase прокидывает в функцию сам — настраивать не нужно.

Фронт: `startQuickMatch()` при наличии бэкенда уходит в `COLOSSO.matchmaking.join/poll`, и при матче открывает **реальное** лобби. Проверка вживую: две вкладки с разными аккаунтами жмут «Партида рапида» — сводятся друг с другом в одно лобби. Если за ~24 сек пары нет, фолбэк на демо-оппонента, чтобы UX не завис.

## 10. Сидинг сетки турнира

Файл: `bracket.sql` (выполнить в SQL Editor после `schema.sql`).

`seed_bracket(p_tournament)` — только для организатора. Берёт зарегистрированные команды, проставляет посев (случайный жребий → `tournament_registrations.seed`), строит сетку на выбывание (дополняет до степени двойки пустыми `BYE`), пишет её в `tournaments.bracket` (jsonb) и переводит статус в `live`. Возвращает сетку в форме, которую рисует прототип:
```json
[ { "name": "Quartas", "m": [ ["LOUD","—","Fluxo","—"], … ] }, … ]
```

Деплой: SQL Editor → `bracket.sql` → Run. Edge Function не нужна (это RPC).

Фронт: `COLOSSO.tournaments.seed(id)`. В карточке турнира, который ты организуешь, появляется кнопка **«Сгенерировать сетку и старт»** → строит сетку и показывает её прямо в детальном окне. Без бэкенда (демо) сетка собирается локально из участников, так что фича работает и для показа. Названия раундов локализуются (Final/Semis/Quartas/Oitavas → PT/ES/EN/RU).

## 11. История матчей

Файл: `matches.sql` (выполнить **после** `glr-xp.sql`). Создаёт таблицу `matches` (по матчу на игрока: соперник, карта, ±GLR, победа/поражение) и **обновляет** `finish_match` — теперь принимает `p_opponent`/`p_map` и пишет строку истории. Старая 2-арг версия дропается и заменяется 4-арг (доп. параметры опциональны).

Фронт: при входе `COLOSSO.matches.list()` подтягивает реальные матчи в профиль («Últimas partidas»); при завершении лобби запись прибавляется сразу. GLR в профиле и на дашборде — живой.

## 12. Заявки в команду (приём/отклонение)

Без новых таблиц — используется `team_applications` из `schema.sql`. В детальном окне команды, которой ты владеешь, появляется блок **«Заявки»** со списком кандидатов и кнопками «Принять / Отклонить»:
- `COLOSSO.teams.listApplications(teamId)` — ожидающие заявки с профилем кандидата.
- `COLOSSO.teams.respondApplication(app, accept, teamName)` — меняет статус, при приёме добавляет игрока в `team_members` и шлёт кандидату уведомление (realtime). Всё под RLS «только владелец команды».

---

### Итоговый список SQL для запуска (по порядку)
1. `schema.sql`  2. `glr-xp.sql`  3. `matchmaking.sql`  4. `bracket.sql`  5. `matches.sql`  6. **`security-hardening.sql`** (последним — закрывает дыры RLS)

Edge Functions: `translate`, `matchmaking` (через дашборд «Via Editor» или `supabase functions deploy`).

См. также `SECURITY.md` (что закрыл аудит RLS) и `../DEPLOY.md` (как выложить сайт онлайн).
