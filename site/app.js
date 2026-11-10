(function () {
  "use strict";

  var STORAGE_KEY = "cloudnotes-lite:notes";

  var form = document.getElementById("note-form");
  var idInput = document.getElementById("note-id");
  var titleInput = document.getElementById("note-title");
  var bodyInput = document.getElementById("note-body");
  var saveBtn = document.getElementById("save-btn");
  var cancelBtn = document.getElementById("cancel-btn");
  var list = document.getElementById("note-list");
  var empty = document.getElementById("empty");
  var count = document.getElementById("note-count");
  var search = document.getElementById("search");

  // Storage can be unavailable (private mode, blocked site data), so fall back to memory.
  var memoryNotes = [];

  function load() {
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      return raw ? JSON.parse(raw) : [];
    } catch (e) {
      return memoryNotes;
    }
  }

  function save(notes) {
    memoryNotes = notes;
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(notes));
    } catch (e) {
      /* keep the in-memory copy */
    }
  }

  function newId() {
    if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
    return Date.now().toString(36) + Math.random().toString(36).slice(2);
  }

  function formatDate(iso) {
    return new Date(iso).toLocaleString(undefined, {
      day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit"
    });
  }

  function resetForm() {
    form.reset();
    idInput.value = "";
    saveBtn.textContent = "Save note";
    cancelBtn.hidden = true;
  }

  function render() {
    var notes = load();
    var query = search.value.trim().toLowerCase();
    var shown = notes.filter(function (n) {
      return !query || n.title.toLowerCase().indexOf(query) !== -1 || n.body.toLowerCase().indexOf(query) !== -1;
    });

    count.textContent = notes.length;
    list.textContent = "";
    empty.hidden = shown.length > 0;
    empty.textContent = notes.length ? "No notes match your search." : "No notes yet. Write one to get started.";

    shown.forEach(function (note) {
      var li = document.createElement("li");
      li.className = "note";

      var h3 = document.createElement("h3");
      h3.textContent = note.title;

      var p = document.createElement("p");
      p.textContent = note.body;

      var meta = document.createElement("div");
      meta.className = "note-meta";
      var time = document.createElement("span");
      time.textContent = (note.updatedAt !== note.createdAt ? "Edited " : "Created ") + formatDate(note.updatedAt);

      var edit = document.createElement("button");
      edit.type = "button";
      edit.className = "link";
      edit.textContent = "Edit";
      edit.addEventListener("click", function () {
        idInput.value = note.id;
        titleInput.value = note.title;
        bodyInput.value = note.body;
        saveBtn.textContent = "Update note";
        cancelBtn.hidden = false;
        titleInput.focus();
      });

      var del = document.createElement("button");
      del.type = "button";
      del.className = "link danger";
      del.textContent = "Delete";
      del.addEventListener("click", function () {
        save(load().filter(function (n) { return n.id !== note.id; }));
        if (idInput.value === note.id) resetForm();
        render();
      });

      meta.appendChild(time);
      meta.appendChild(edit);
      meta.appendChild(del);
      li.appendChild(h3);
      li.appendChild(p);
      li.appendChild(meta);
      list.appendChild(li);
    });
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var title = titleInput.value.trim();
    var body = bodyInput.value.trim();
    if (!title || !body) return;

    var notes = load();
    var now = new Date().toISOString();
    var id = idInput.value;

    if (id) {
      notes = notes.map(function (n) {
        return n.id === id ? { id: n.id, title: title, body: body, createdAt: n.createdAt, updatedAt: now } : n;
      });
    } else {
      notes.unshift({ id: newId(), title: title, body: body, createdAt: now, updatedAt: now });
    }

    save(notes);
    resetForm();
    render();
  });

  cancelBtn.addEventListener("click", resetForm);
  search.addEventListener("input", render);

  // Deployment facts panel.
  var host = window.location.hostname || "local file";
  document.getElementById("fact-host").textContent = host;
  document.getElementById("fact-proto").textContent = window.location.protocol.replace(":", "").toUpperCase();
  var build = window.CLOUDNOTES_BUILD || { version: "local", builtAt: "not deployed" };
  document.getElementById("fact-build").textContent = build.version + " (" + build.builtAt + ")";
  if (!/cloudfront\.net$/.test(host)) {
    document.getElementById("host-badge").textContent = "Running locally";
  }

  render();
})();
