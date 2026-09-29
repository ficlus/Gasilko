# Plan road routes (M7.5)

Deploy the `plan-routes` Edge Function after applying
`20260929130000_plan_road_routes.sql` through the normal deployment process.
Neither has been deployed by this change.

Configure `GRAPHHOPPER_API_KEY` as a **Supabase Edge secret**. Supabase supplies
`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`.
No GraphHopper credential belongs in Android, configuration committed to Git,
database rows, request diagnostics or logs. The handler deliberately never logs
provider exceptions, URLs or response bodies.

The function verifies the user's bearer token with Supabase Auth. Keep the
default Supabase gateway JWT check enabled as well. The caller's JWT authorizes
the prepare/read RPCs. Only the Edge service credential can call
the receipt RPC, which rechecks the verified user's live manager/admin access
and the exact saved input before atomically replacing every team's route.
Direct authenticated writes to route data are forbidden. Existing organization
locks, plan version and operation UUID conventions protect concurrent changes
and acknowledged retries.

The isolated `RoadProvider` interface uses GraphHopper's car matrix and routing
endpoints. Matrix travel time determines nearest-neighbour order and bounded
directed 2-opt improvement; road distance breaks ties. Team and hydrant UUIDs
provide deterministic tie ordering. With no plan start, the lowest hydrant UUID
in each team is the fixed anchor; return-to-start closes there. The final provider
path supplies geometry and driving totals (inspection time is not included).
There is no straight-line fallback, automatic reassignment or navigation.

Resource limits: 20 teams, 500 selected hydrants, 100 input positions
per team including an explicit start, 4 MB retained provider response/result and
a 100-second request deadline. GraphHopper subscription limits may be lower.
Exceeding a limit, missing coordinates, missing assignments or an unroutable
point fails the whole calculation. A prior successful result survives failure
if still valid. Changes to selected teams/items, assignment, start, return flag
or authoritative hydrant coordinates invalidate cached server results; devices
receive that invalidation on the next plan refresh.

Room migration 11→12 stores scoped route results and item stop order. Android
reads those results offline, including locally drawn stop numbers with the
existing fallback map style. Offline basemap coverage still uses the existing
map downloads. Online recalculation never joins the field-operation sync queue.

Manual verification (not executed):

- Configure the secret and deploy the migration/function in a review environment.
- Calculate multiple teams, one-stop/empty teams, with/without start, and open/
  return routes. Check road distance, duration, stop order and map geometry.
- Repeat identical inputs and retry the same request after a lost response.
- Reject missing/unassigned/unreachable locations and provider quota failures
  without partially replacing results or modifying assignments/selections.
- Edit assignment/start/return/coordinates; check invalidation and refresh.
- Race recalculation with a plan change or membership revocation; check rejection.
- Verify manager/admin access, firefighter/cross-organization denial, account/org
  switching, Room upgrade, offline reopening and default/Slovenian/German UI.

Contracts: [GraphHopper API](https://docs.graphhopper.com/openapi) and
[attribution](https://www.graphhopper.com/attribution/).
