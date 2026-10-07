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
client = publisher["GitHubCLIClient"](repo)
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

before = retained()
release_id = None
emit("start", tag=tag, source=os.environ["GITHUB_SHA"], target=target, token="Actions contents:write")
try:
    assert client.resolve_tag(tag) is None
    assert by_tag() is None
    client.create_draft(tag, target, title, notes, tag_exists=False)
    selected = by_tag()
    assert selected and selected["tagName"] == tag and selected["isDraft"] is True
    release_id = selected["databaseId"]
    emit("created", release_id=release_id, selected=selected)
    query = "query($tag:String!,$endCursor:String){repository(owner:\"cbusillo\",name:\"context-panel\"){release(tagName:$tag){databaseId} releases(first:100,after:$endCursor){nodes{databaseId tagName} pageInfo{hasNextPage endCursor}}}}"
    pages = api("graphql", "--paginate", "--slurp", "-f", f"query={query}", "-f", f"tag={tag}")
    emit("graphql_lookup", selected=[p["data"]["repository"]["release"] for p in pages], matching_list_nodes=[n for p in pages for n in p["data"]["repository"]["releases"]["nodes"] if n["tagName"] == tag], page_count=len(pages))
    try:
        draft = client.get_release(tag)
        emit("publisher_lookup", release_id=draft["id"] if draft else None)
    except publisher["PublicationError"] as error:
        emit("publisher_lookup_error", message=str(error))
finally:
    if release_id is not None:
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
