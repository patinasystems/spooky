//! App-owned JSON-lines adapter. No socket, login item, content search, or keep-warm loop.
use fsearch::{Engine, Options, Query};
use serde::{Deserialize, Serialize};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};

const MAX_LINE: usize = 16 * 1024;
const MAX_QUERY: usize = 1024;
const MAX_RESULTS: usize = 200;

#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
struct Request {
    id: String,
    op: String,
    #[serde(default)]
    query: String,
    #[serde(default)]
    near: String,
    scope: Option<String>,
    #[serde(default)]
    limit: usize,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Entry {
    path: String,
    name: String,
    is_directory: bool,
}

#[derive(Serialize)]
struct Response<'a> {
    id: &'a str,
    entries: Vec<Entry>,
    error: Option<String>,
    cancelled: bool,
    state: Option<&'static str>,
}

#[derive(Default)]
struct Queue {
    pending: Option<Request>,
    active: Option<String>,
    cancelled: bool,
}

impl Queue {
    fn enqueue(&mut self, request: Request) -> Option<Request> {
        self.cancelled = self.active.is_some();
        self.pending.replace(request)
    }

    fn cancel(&mut self, id: &str) -> Option<Request> {
        if self.active.as_deref() == Some(id) {
            self.cancelled = true;
        }
        if self.pending.as_ref().is_some_and(|r| r.id == id) {
            self.pending.take()
        } else {
            None
        }
    }
}

fn respond(output: &Mutex<io::Stdout>, response: Response<'_>) {
    let mut output = output.lock().unwrap();
    // Broken stdout means the app has exited; never retain a background indexer.
    if serde_json::to_writer(&mut *output, &response).is_err()
        || output.write_all(b"\n").is_err()
        || output.flush().is_err()
    {
        std::process::exit(0);
    }
}

fn cancelled(output: &Mutex<io::Stdout>, id: &str) {
    respond(output, Response { id, entries: Vec::new(), error: None, cancelled: true, state: None });
}

fn validate(request: &Request) -> Result<(), String> {
    if request.id.is_empty() || request.id.len() > 64 || !request.id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err("invalid request id".into());
    }
    if request.op == "cancel" || request.op == "status" {
        return Ok(());
    }
    if request.op != "search" || request.query.len() > MAX_QUERY || request.query.contains('\0') {
        return Err("invalid filename query (maximum 1024 UTF-8 bytes)".into());
    }
    if !valid_path(&request.near) || request.scope.as_ref().is_some_and(|s| !valid_path(s)) {
        return Err("search folders must be absolute paths".into());
    }
    Ok(())
}

fn valid_path(path: &str) -> bool {
    path.starts_with('/') && !path.contains('\0') && path.len() <= 4096
}

fn make_query(request: &Request) -> Query {
    let mut query = Query::literal_names(&request.query);
    query.scope = request.scope.as_ref().map(|path| {
        if path == "/" { b"/".to_vec() } else { path.trim_end_matches('/').as_bytes().to_vec() }
    });
    // A bounded extra candidate window allows cwd proximity to break ranking ties.
    query.limit = request.limit.clamp(1, MAX_RESULTS).saturating_mul(2);
    query
}

fn proximity(path: &Path, near: &Path) -> usize {
    path.components().zip(near.components()).take_while(|(a, b)| a == b).count()
}

fn search(engine: &Engine, request: &Request) -> Result<Vec<Entry>, String> {
    let mut found = engine.search(&make_query(request))?;
    let near = Path::new(&request.near);
    found.sort_by(|a, b| b.score.cmp(&a.score)
        .then_with(|| proximity(&b.path, near).cmp(&proximity(&a.path, near)))
        .then_with(|| a.path.cmp(&b.path)));
    Ok(found.into_iter().filter_map(|hit| {
        // Never insert a lossy replacement for a non-UTF-8 filesystem name.
        let path = hit.path.to_str()?.to_owned();
        let name = hit.path.file_name()?.to_str()?.to_owned();
        let kind = hit.kind & 3;
        let is_directory = kind == fsearch::walk::KIND_DIR
            || (kind == fsearch::walk::KIND_LINK && hit.path.is_dir());
        Some(Entry { path, name, is_directory })
    }).take(request.limit.clamp(1, MAX_RESULTS)).collect())
}

fn read_line(reader: &mut impl BufRead) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(if line.is_empty() { None } else { Some(line) });
        }
        let end = available.iter().position(|b| *b == b'\n').map(|n| n + 1);
        let count = end.unwrap_or(available.len());
        if line.len() + count > MAX_LINE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "request too large"));
        }
        line.extend_from_slice(&available[..count]);
        reader.consume(count);
        if end.is_some() { return Ok(Some(line)); }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // The private index is app state, not a shared fsearch daemon's index.
    unsafe { libc::umask(0o077); }
    let index = std::env::args_os().nth(1).map(PathBuf::from).ok_or("missing index directory")?;
    if !index.is_absolute() { return Err("index directory must be absolute".into()); }
    let home = std::env::var("HOME")?;
    // Startup indexing is independent of picker/search requests. Saved indexes
    // load on the engine's worker; status reports ready only after publication.
    let engine = Engine::start_names_only(Options { dir: index, home, skip: None })?;
    let work = Arc::new((Mutex::new(Queue::default()), Condvar::new()));
    let output = Arc::new(Mutex::new(io::stdout()));
    let worker_queue = Arc::clone(&work);
    let worker_output = Arc::clone(&output);
    let search_engine = engine.clone();
    std::thread::Builder::new().name("spooky-fsearch-requests".into()).spawn(move || {
        fsearch::no_materialize();
        loop {
            let request = {
                let (lock, condition) = &*worker_queue;
                let mut queue = lock.lock().unwrap();
                while queue.pending.is_none() { queue = condition.wait(queue).unwrap(); }
                let request = queue.pending.take().unwrap();
                queue.active = Some(request.id.clone());
                queue.cancelled = false;
                request
            };
            let result = search(&search_engine, &request);
            let was_cancelled = {
                let mut queue = worker_queue.0.lock().unwrap();
                queue.active = None;
                queue.cancelled
            };
            if was_cancelled {
                cancelled(&worker_output, &request.id);
            } else {
                let (entries, error) = match result { Ok(entries) => (entries, None), Err(error) => (Vec::new(), Some(error)) };
                respond(&worker_output, Response { id: &request.id, entries, error, cancelled: false, state: None });
            }
        }
    })?;
    let mut stdin = io::stdin().lock();
    while let Some(line) = read_line(&mut stdin)? {
        let request: Request = match serde_json::from_slice(&line) {
            Ok(request) => request,
            Err(_) => continue,
        };
        if let Err(error) = validate(&request) {
            respond(&output, Response { id: &request.id, entries: Vec::new(), error: Some(error), cancelled: false, state: None });
            continue;
        }
        // A readiness poll must neither queue behind nor supersede a search.
        if request.op == "status" {
            let state = if engine.status().ready { "ready" } else { "creating" };
            respond(&output, Response { id: &request.id, entries: Vec::new(), error: None,
                                       cancelled: false, state: Some(state) });
            continue;
        }
        let replaced = {
            let mut queue = work.0.lock().unwrap();
            if request.op == "cancel" { queue.cancel(&request.id) } else { queue.enqueue(request) }
        };
        if let Some(replaced) = replaced { cancelled(&output, &replaced.id); }
        work.1.notify_one();
    }
    // Returning from main terminates library background threads. No daemon survives the app.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(id: &str, query: &str) -> Request {
        Request { id: id.into(), op: "search".into(), query: query.into(), near: "/tmp".into(), scope: None, limit: 100 }
    }

    #[test]
    fn filename_query_never_interprets_dsl() {
        for text in ["grep:secret", "regex:.*", "sym:foo", "git:status", "!name", "^start", "*.rs", "limit:999999"] {
            let q = make_query(&request("a", text));
            assert!(q.grep.is_none() && q.name_re.is_none() && q.path_re.is_none());
            assert!(q.globs.is_empty() && q.exts.is_empty());
            assert_eq!(q.tokens[0].text, text.as_bytes());
            assert!(!q.tokens[0].negate);
        }
    }

    #[test]
    fn scope_and_limit_are_structured_and_bounded() {
        let mut r = request("a", "in:/private");
        r.scope = Some("/tmp/fixture/".into());
        r.limit = usize::MAX;
        let q = make_query(&r);
        assert_eq!(q.scope.as_deref(), Some(&b"/tmp/fixture"[..]));
        assert_eq!(q.limit, MAX_RESULTS * 2);
    }

    #[test]
    fn new_requests_replace_only_queued_work_and_cancel_active() {
        let mut q = Queue { active: Some("first".into()), ..Default::default() };
        assert!(q.enqueue(request("second", "x")).is_none());
        assert!(q.cancelled);
        assert_eq!(q.enqueue(request("third", "y")).unwrap().id, "second");
        assert!(q.cancel("second").is_none());
        assert_eq!(q.pending.as_ref().unwrap().id, "third");
        assert_eq!(q.cancel("third").unwrap().id, "third");
    }

    #[test]
    fn requests_and_lines_are_bounded() {
        let mut r = request("a", "x");
        r.query = "x".repeat(MAX_QUERY + 1);
        assert!(validate(&r).is_err());
        assert!(read_line(&mut io::Cursor::new(vec![b'x'; MAX_LINE + 1])).is_err());
        assert_eq!(read_line(&mut io::Cursor::new(b"abc\nrest")).unwrap().unwrap(), b"abc\n");
    }

    #[test]
    fn status_protocol_needs_no_synthetic_filename_query() {
        let r: Request = serde_json::from_str(r#"{"id":"status-1","op":"status"}"#).unwrap();
        assert!(validate(&r).is_ok());
        let response = Response { id: &r.id, entries: Vec::new(), error: None,
                                  cancelled: false, state: Some("creating") };
        let json = serde_json::to_value(response).unwrap();
        assert_eq!(json["state"], "creating");
        assert_eq!(json["entries"], serde_json::json!([]));
    }

    #[test]
    fn unicode_names_keep_normalization_alternative_and_token_bounds() {
        let q = Query::literal_names("café");
        assert!(q.alt.is_some());
        assert_eq!(Query::literal_names("1 2 3 4 5 6 7 8 9").tokens.len(), 8);
    }
}
