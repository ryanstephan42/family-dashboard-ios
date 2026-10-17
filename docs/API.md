# API contract (for native clients)

Base URL: `https://<your-server>/api`. All bodies are JSON unless noted.
Dates are ISO-8601 UTC strings. Authenticated routes need
`Authorization: Bearer <token>`; missing token -> 401, invalid token -> 403.
The server requires `JWT_SECRET` to be set and refuses to start without it.

## Public
| Method | Path | Notes |
|---|---|---|
| GET | `/config` | `{ apiVersion, minClientApiVersion, nextcloudCalendarEmbedUrl, chatUrl, budgetUrl }`. Clients should compare `apiVersion` with the API version they were built for. |
| POST | `/users/register` | `{ username, password, name }` -> 201 `{ message }` |
| POST | `/users/login` | `{ username, password }` -> `{ token, user: { id, username, name } }` |
| GET | `/health` (no `/api` prefix) | liveness |

## Users (auth)
`GET /users` -> `[{ id, name, username }]`

## Tasks (auth)
- `GET /tasks?type=FAMILY|PRIVATE|CHORE&assignedToMe=true&status=DONE` -> `[Task]`
  (without `status=DONE`, returns non-done tasks)
- `POST /tasks` `{ title, description?, type, priority, dueDate?, assigneeId?, steps?: [{content}], isRepeating?, repeatFrequency? }` -> Task
- `PUT /tasks/:id` partial update -> Task
- `DELETE /tasks/:id`
- `PATCH /tasks/:taskId/steps/:stepId` toggle/update a step

```json
{ "id": "uuid", "title": "Dishes", "description": null, "status": "TODO",
  "type": "FAMILY", "priority": "MEDIUM", "dueDate": "2026-10-20T00:00:00.000Z",
  "isRepeating": false, "repeatFrequency": null,
  "steps": [{ "id": "uuid", "content": "Load", "completed": false, "taskId": "uuid" }],
  "creatorId": "uuid", "creator": { "id": "uuid", "name": "Ryan" },
  "assigneeId": null, "assignee": null,
  "createdAt": "...", "updatedAt": "..." }
```
status: `TODO | IN_PROGRESS | DONE`; priority: `LOW | MEDIUM | HIGH`.

## Events (auth)
- `GET /events`, `POST /events` `{ title, description?, startTime, endTime?, location?, isRepeating?, repeatFrequency?, color? }`, `DELETE /events/:id`
- Event: `{ id, title, description, startTime, endTime, location, isRepeating, repeatFrequency, color, creatorId, createdAt, updatedAt }`

## Grocery (auth)
- `GET /grocery`; `POST /grocery` `{ items: [{ name, quantity?, details?, category? }] }` -> 201 `[GroceryItem]`
- `PUT /grocery/:id`; `DELETE /grocery/:id`; `POST /grocery/:id/purchase`
- `GET /grocery/suggestions`; `GET /grocery/preferences`
- GroceryItem: `{ id, name, quantity, details, category, completed, createdAt, updatedAt }`

## Inventory (auth)
`GET /inventory`, `/inventory/unit-options`, `/inventory/low-stock`,
`/inventory/barcode/:code`; `POST /inventory`; `PUT /inventory/:id`;
`PATCH /inventory/:id/quantity`; `POST /inventory/:id/photo` (multipart field
`photo`); `DELETE /inventory/:id/photo`; `DELETE /inventory/:id`.
FoodItem: `{ id, name, quantity, unit, category, location, purchaseDate, trackExpiration, expirationDate, notes, barcode, parLevel, lowStock, photoUrl, createdAt, updatedAt }`.
`photoUrl` is a path like `/uploads/...` relative to the server origin (not `/api`).

## Receipt (auth)
`POST /receipt/scan` multipart field `receipt`.

## Meals (auth)
`GET /meals/status`, `/meals/recipes`, `/meals/recipes/:slug/match`,
`/meals/what-can-i-make`; `POST /meals/recipes/:slug/link`;
`DELETE /meals/recipes/:slug/link/:ingredientName`.

## Widget
`POST /widget/token`, `DELETE /widget/token` (auth); `GET /widget/tasks` uses the widget token.

Exact request/response details for each route are in `server/src/routes/*.ts`.
