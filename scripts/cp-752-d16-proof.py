"""Disposable CP-752-D16 Actions-token experiment; removed before handoff."""
import datetime
import json
import os
import runpy
import subprocess
import uuid

publisher = runpy.run_path("scripts/publish-github-release.py")
assert os.environ["GITHUB_REPOSITORY"] == "cbusillo/context-panel"
assert os.environ["GITHUB_REF"] == "refs/heads/work/cp-752-d16-draft-proof"
repo = os.environ["GITHUB_REPOSITORY"]
target = os.environ["PROOF_TARGET"]
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
tag = f"publisher-proof-{stamp}-{os.environ['GITHUB_RUN_ID']}-{uuid.uuid4().hex[:8]}"
title = f"TEST ONLY - NEVER PUBLISH - {tag}"
identity = publisher["ReleaseIdentity"](tag, target, "publisher-proof", os.environ["GITHUB_RUN_ID"], ())
notes = publisher["render_notes"](title, identity)

def emit(event, **fields):
    print(json.dumps({"event": event, **fields}), flush=True)

def api(*args, absent=False):
    result = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if absent and result.returncode and "HTTP 404" in result.stderr:
        return None
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout) if result.stdout else None

def by_tag():
    return api("graphql", "-f", "query=query($tag:String!){repository(owner:\"cbusillo\",name:\"context-panel\"){release(tagName:$tag){databaseId tagName isDraft}}}", "-f", f"tag={tag}")["data"]["repository"]["release"]

def retained():
    r = api(f"repos/{repo}/releases/405252613")
    return {k: r[k] for k in ("id", "tag_name", "draft", "target_commitish", "body", "assets", "published_at")}

class StopBeforePublication(Exception):
    pass

class ProofClient(publisher["GitHubCLIClient"]):
    creates = 0

    def _run(self, arguments, **kwargs):
        result = super()._run(arguments, **kwargs)
        if arguments[:2] == ["api", "graphql"]:
            if result.returncode == 0:
                value = json.loads(result.stdout)
                pages = value if isinstance(value, list) else [value]
                emit("publisher_graphql", selected=[p["data"]["repository"]["release"] for p in pages], matching_list_nodes=[n for p in pages for n in p["data"]["repository"].get("releases", {}).get("nodes", []) if n["tagName"] == tag])
        elif arguments[:1] == ["api"] and len(arguments) == 2:
            value = json.loads(result.stdout) if result.returncode == 0 else None
            emit("publisher_rest", endpoint=arguments[1], code=result.returncode, release_id=value.get("id") if value else None)
        return result

    def create_draft(self, *args, **kwargs):
        self.creates += 1
        return super().create_draft(*args, **kwargs)

    def publish_draft(self, requested_tag):
        assert requested_tag == tag
        emit("publication_intercepted", creates=self.creates)
        raise StopBeforePublication()

client = ProofClient(repo)
before = retained()
release_id = None
emit("start", tag=tag, source=os.environ["GITHUB_SHA"], target=target, token="Actions contents:write")
try:
    for attempt in ("create", "adopt"):
        try:
            publisher["publish_release"](client, identity, title=title, notes=title)
            raise AssertionError("unexpected publication")
        except StopBeforePublication:
            emit("publisher_transaction", attempt=attempt, result="verified draft; publication intercepted", creates=client.creates)
        except publisher["PublicationError"] as error:
            emit("publisher_lookup_error", attempt=attempt, message=str(error))
            break
    selected = by_tag()
    assert selected and selected["tagName"] == tag and selected["isDraft"] is True
    release_id = selected["databaseId"]
    emit("created", release_id=release_id, selected=selected)
    query = "query($tag:String!,$endCursor:String){repository(owner:\"cbusillo\",name:\"context-panel\"){release(tagName:$tag){databaseId} releases(first:100,after:$endCursor){nodes{databaseId tagName} pageInfo{hasNextPage endCursor}}}}"
    pages = api("graphql", "--paginate", "--slurp", "-f", f"query={query}", "-f", f"tag={tag}")
    emit("graphql_lookup", selected=[p["data"]["repository"]["release"] for p in pages], matching_list_nodes=[n for p in pages for n in p["data"]["repository"]["releases"]["nodes"] if n["tagName"] == tag], page_count=len(pages))
finally:
    selected = by_tag()
    if selected is not None:
        release_id = selected["databaseId"]
        draft = api(f"repos/{repo}/releases/{release_id}")
        assert release_id != before["id"] and draft["id"] == release_id
        assert draft["draft"] is True and draft["tag_name"] == tag
        assert draft["name"] == title and draft["body"] == notes
        assert draft["target_commitish"] == target and draft["assets"] == []
        assert draft["published_at"] is None
        api("--method", "DELETE", f"repos/{repo}/releases/{release_id}")
        assert api(f"repos/{repo}/releases/{release_id}", absent=True) is None
        assert by_tag() is None
        emit("deleted_and_absent", release_id=release_id)
    assert client.resolve_tag(tag) is None
    assert retained() == before
    emit("preserved", retained_release=before["id"], test_git_tag="absent")
