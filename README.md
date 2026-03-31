# bigquery agent

ai data analyst that lets you talk to bigquery in plain english. ask it questions, it writes SQL, runs it, gives you results. gemini under the hood.

## whats in here

three pieces:

**backend** `/backend`
python fastapi wrapping google ADK. the agent runs gemini-3-pro-preview with bigquery tools... it can list datasets, pull schemas, run queries. sessions are in-memory so they die on cold start, thats fine for this. runs on uvicorn.

**frontend** `/frontend`
hono gateway serving static files and proxying `/api/*` to the backend. before it proxies it grabs an OIDC identity token and injects it into the request headers. this is required because the backend is internal-only, IAM enforced. the UI is vanilla typescript, dark theme, chat interface with markdown rendering.

**infra** `/terraform` + `deploy.sh`
two cloud run services behind IAP. backend is `INGRESS_TRAFFIC_INTERNAL_ONLY` so its topologically unreachable from the internet. frontend is public but IAP gated. secrets go through secret manager, not env vars. terraform manages all the IAM bindings and service config.

## the auth chain

```
you (google account) --> IAP --> frontend
frontend-sa --> OIDC identity token --> backend
```

frontend service account has `roles/run.invoker` on the backend. thats it. no api keys in headers, no shared secrets. identity tokens or nothing.

## deploying

you need: `gcloud` (authed), `terraform`, `bash`

```bash
./deploy.sh
```

it will:
1. list your gcp projects, you pick one
2. prompt for gemini api key (checks env first)
3. prompt for IAP domain (infers from your gcloud account)
4. enable all the apis
5. build both containers via cloud build + buildpacks
6. terraform apply

when its done it prints the frontend URL. go there, log in with google, start asking questions.

## talking to it

once youre in you can just ask stuff like:

- "what tables are available"
- "show me the schema for the users table"
- "top 10 longest calls from last week"

it figures out the SQL, runs it, formats the results. if it needs to chain multiple queries to answer you it will.

## prerequisites

- gcloud cli, authenticated
- terraform in PATH
- a gemini api key
- a gcp project you can deploy to

## stuff to know

- sessions dont survive instance restarts... thats by design, not a bug
- backend has no swagger UI in prod
- no dockerfiles, buildpacks only
- the api key goes into secret manager, never as a plaintext env var
- IAP domain defaults to whatever domain your gcloud account is on
