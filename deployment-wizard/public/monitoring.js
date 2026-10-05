'use strict';

/*
 * Client code for the Monitoring pages. One init function per page; the
 * helpers they share (formatters, monFetch, session expiry) live in
 * monitoring-common.js, which must be loaded first. openModal, closeModal,
 * escapeHtml and copyText come from wizard-ui.js.
 *
 * Every piece of dynamic text goes through escapeHtml() or textContent.
 */

function byId(id) {
  return document.getElementById(id);
}

function pillHtml(pill) {
  var title = pill.title ? ' title="' + escapeHtml(pill.title) + '"' : '';
  return '<span class="pill ' + pill.cls + '"' + title + '>' + escapeHtml(pill.text) + '</span>';
}

var BADGE_FOR = { ok: 'badge-ok', warn: 'badge-warn', fail: 'badge-fail' };

// Own keys only: a status is data from a script, and "constructor" must not
// resolve to Object's function.
function badgeClass(status) {
  return Object.prototype.hasOwnProperty.call(BADGE_FOR, status) ? BADGE_FOR[status] : 'badge-pending';
}

// Rewrites an element's text only when it differs, so that a status element
// polled every few seconds does not re-announce the same sentence.
function setTextIfChanged(el, text) {
  if (el.textContent !== text) el.textContent = text;
}

// One <li> of a .checklist: OK/WARN/FAIL badge plus a message. Line breaks in
// the message are kept (script output can be multi-line).
function checkRowHtml(status, message, extraHtml, label) {
  var badge = label || String(status || 'warn').toUpperCase();
  return '<li><span class="badge ' + badgeClass(status) + '">' + escapeHtml(badge) + '</span>' +
    '<span>' + escapeHtml(message).replace(/\n/g, '<br>') + (extraHtml || '') + '</span></li>';
}

// Download links. A plain link would save the JSON error body as a file when
// the session has expired, so the click is taken over:
//   'blob'   - small files (CSV, support bundles): fetched, then saved from memory;
//   'follow' - the log (can be large): a cheap authenticated request first, then
//              the browser follows the link.
// Errors go to showError(message); an expired session shows the banner.
function runDownload(e, link, mode, showError) {
  e.preventDefault();
  var href = link.getAttribute('href');
  if (!href || href === '#') return;
  var job = mode === 'blob'
    ? monDownload(href, link.getAttribute('download') || 'download')
    : monPreflightThenFollow(href);
  job.catch(function (err) {
    if (err && err.expired) return;
    showError(err && err.message ? err.message : 'The download failed.');
  });
}

function guardDownload(link, mode, showError) {
  link.addEventListener('click', function (e) { runDownload(e, link, mode, showError); });
}

// ===========================================================================
// Overview
// ===========================================================================

var SERVICES_POLL_MS = 10000;

function initMonitoringOverview(data) {
  var tbody = byId('svcTable').tBodies[0];
  // svcTime carries the refresh timestamp (hidden from screen readers so a
  // 10-second poll is not announced); svcUpdated is the live region and only
  // holds problems.
  var updated = byId('svcUpdated');
  var timeEl = byId('svcTime');
  var refreshBtn = byId('svcRefresh');
  var rerunBtn = byId('statusRerun');
  var modal = byId('restart-modal');
  var runActive = Boolean(data && data.runActive);

  var timer = null;
  var stopped = false;
  var loading = false;
  var pendingPayload = null;
  var restartTarget = null;

  monOnExpire(function () {
    stopped = true;
    clearTimeout(timer);
  });

  function modalOpen() {
    return modal.classList.contains('modal-open');
  }

  // ---- Services table ----

  // A row is built once (createRow) and then only its changed cells are
  // rewritten (updateRow). The 10-second refresh therefore never replaces a
  // button: a click that lands during a refresh is not lost, keyboard focus
  // stays where it is, and references held by the page stay valid.
  //
  // Cell order: service (+ version line), state, health, uptime, restarts,
  // version, CPU, memory, actions. data-label is what the stacked mobile
  // layout prints in front of a value (styles.css, "Services table").
  function serviceCells(row) {
    var running = row.state === 'running';
    var memTitle = row.memLimitBytes != null
      ? 'of ' + fmtBytes(row.memLimitBytes) + (row.memPct != null ? ' (' + fmtPct(row.memPct) + ')' : '')
      : '';
    var tagHtml = '<span' + (row.image ? ' title="' + escapeHtml(row.image) + '"' : '') + '>' + escapeHtml(row.imageTag || MON_DASH) + '</span>';
    return [
      '<span class="svc-name">' + escapeHtml(row.service) + '</span><span class="svc-version cell-mono">' + tagHtml + '</span>',
      pillHtml(statePill(row)),
      pillHtml(healthPill(row)),
      running ? fmtDuration(row.uptimeSec) : MON_DASH,
      row.restarts != null ? escapeHtml(row.restarts) : MON_DASH,
      tagHtml,
      fmtPct(row.cpuPct),
      '<span' + (memTitle ? ' title="' + escapeHtml(memTitle) + '"' : '') + '>' + fmtBytes(row.memUsageBytes) + '</span>'
    ];
  }

  function restartDisabled(row) {
    return runActive || row.state === 'missing';
  }

  // The actions cell depends only on the service name (its key), so it is
  // written once; updateRow() only toggles the button's disabled state.
  function serviceRowSkeletonHtml(service) {
    var svc = escapeHtml(service);
    return '<th scope="row" role="rowheader"></th>' +
      '<td role="cell" data-label="State"></td>' +
      '<td role="cell" data-label="Health"></td>' +
      '<td class="num" role="cell" data-label="Uptime"></td>' +
      '<td class="num" role="cell" data-label="Restarts"></td>' +
      '<td class="cell-mono col-version" role="cell" data-label="Version"></td>' +
      '<td class="num" role="cell" data-label="CPU"></td>' +
      '<td class="num" role="cell" data-label="Memory"></td>' +
      '<td class="cell-actions" role="cell">' +
        '<a class="btn btn-secondary btn-sm" href="/monitoring/logs?service=' + encodeURIComponent(service) +
          '" aria-label="Show logs of ' + svc + '">Logs</a>' +
        '<button type="button" class="btn btn-secondary btn-sm" data-restart="' + svc + '"' +
          ' aria-label="Restart ' + svc + '">Restart</button>' +
      '</td>';
  }

  function updateRow(tr, row) {
    var next = serviceCells(row);
    changedIndexes(tr._cells, next).forEach(function (i) {
      var cellMarkup = next[i]; // built by serviceCells(): every dynamic part escaped
      tr.children[i].innerHTML = cellMarkup;
    });
    tr._cells = next;
    var btn = tr.querySelector('[data-restart]');
    var off = restartDisabled(row);
    if (btn.disabled !== off) btn.disabled = off;
  }

  function createRow(row) {
    var tr = document.createElement('tr');
    tr.setAttribute('data-service', row.service);
    // Explicit roles: the phone layout turns the table into blocks, and some
    // browsers/screen readers then stop treating it as a table.
    tr.setAttribute('role', 'row');
    tr.innerHTML = serviceRowSkeletonHtml(row.service);
    updateRow(tr, row);
    return tr;
  }

  function emptyRowHtml(text) {
    return '<tr class="mon-empty-row" role="row"><td colspan="9" class="cell-empty" role="cell">' + escapeHtml(text) + '</td></tr>';
  }

  function serviceRows() {
    var rows = Object.create(null);
    Array.prototype.forEach.call(tbody.querySelectorAll('tr[data-service]'), function (tr) {
      rows[tr.getAttribute('data-service')] = tr;
    });
    return rows;
  }

  function showEmpty(text) {
    var only = tbody.children.length === 1 ? tbody.children[0] : null;
    if (only && only.classList.contains('mon-empty-row') && only.textContent === text) return;
    tbody.innerHTML = emptyRowHtml(text);
  }

  function syncServices(services) {
    var rows = serviceRows();
    var diff = diffRows(Object.keys(rows), services.map(function (s) { return s.service; }));
    diff.remove.forEach(function (key) { tbody.removeChild(rows[key]); });
    // The "Loading…" or "no services" placeholder is the only row without a key.
    Array.prototype.forEach.call(tbody.querySelectorAll('tr.mon-empty-row'), function (tr) { tbody.removeChild(tr); });
    services.forEach(function (row, i) {
      var tr = rows[row.service];
      if (tr && diff.keep.indexOf(row.service) !== -1) updateRow(tr, row);
      else { tr = createRow(row); rows[row.service] = tr; }
      // Only moves a row that is not already in its place.
      if (tbody.children[i] !== tr) tbody.insertBefore(tr, tbody.children[i] || null);
    });
  }

  function renderServices(payload) {
    var failed = composeFailedText(payload);
    if (failed && !payload.services.length) showEmpty(failed);
    else if (!payload.dockerAvailable) showEmpty('Docker is not reachable from the wizard.');
    else if (!payload.services.length) showEmpty('No services were found in the compose project.');
    else syncServices(payload.services);

    if (payload.dockerAvailable) {
      setTextIfChanged(timeEl, 'Updated ' + fmtTime(payload.generatedAt) + ' UTC.');
    } else {
      setTextIfChanged(timeEl, '');
    }
    if (failed) setTextIfChanged(updated, failed + ' Trying again in 10 seconds.');
    else if (!payload.dockerAvailable) setTextIfChanged(updated, 'Docker is not reachable. Trying again in 10 seconds.');
    else setTextIfChanged(updated, '');
  }

  function loadServices() {
    if (loading || stopped) return Promise.resolve();
    loading = true;
    refreshBtn.disabled = true;
    return monFetch('/api/monitoring/services').then(function (payload) {
      // Do not swap the rows out from under an open dialog.
      if (modalOpen()) pendingPayload = payload;
      else { pendingPayload = null; renderServices(payload); }
    }).catch(function (err) {
      if (err && err.expired) return;
      setTextIfChanged(updated, 'Could not refresh the service list: ' + err.message + ' Trying again in 10 seconds.');
    }).then(function () {
      loading = false;
      refreshBtn.disabled = false;
    });
  }

  // setTimeout chained after each load, never setInterval: a slow
  // `docker stats` must not stack overlapping requests.
  function schedule() {
    if (stopped) return;
    clearTimeout(timer);
    timer = setTimeout(tick, SERVICES_POLL_MS);
  }

  function tick() {
    if (stopped) return;
    if (document.hidden) { schedule(); return; }
    if (pendingPayload && !modalOpen()) { renderServices(pendingPayload); pendingPayload = null; }
    loadServices().then(schedule);
  }

  refreshBtn.addEventListener('click', function () {
    clearTimeout(timer);
    loadServices().then(schedule);
  });

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && !stopped) { clearTimeout(timer); tick(); }
  });

  loadServices().then(schedule);

  // ---- Restart dialog ----

  var confirmBtn = byId('restartConfirm');
  var errBox = byId('restartError');

  tbody.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('[data-restart]') : null;
    if (!btn || btn.disabled) return;
    restartTarget = btn.getAttribute('data-restart');
    byId('restart-modal-title').textContent = 'Restart ' + restartTarget + '?';
    byId('restartBody').textContent = restartImpact(restartTarget);
    errBox.textContent = '';
    confirmBtn.disabled = false;
    openModal('restart-modal');
  });

  byId('restartCancel').addEventListener('click', function () {
    closeModal('restart-modal');
  });

  confirmBtn.addEventListener('click', function () {
    if (!restartTarget) return;
    confirmBtn.disabled = true;
    errBox.textContent = '';
    monFetch('/api/monitoring/restart', monJson({ service: restartTarget })).then(function (res) {
      location.href = '/monitoring/restart-progress?runId=' + encodeURIComponent(res.runId);
    }).catch(function (err) {
      if (err && err.expired) { closeModal('restart-modal'); return; }
      errBox.textContent = err.message;
      confirmBtn.disabled = false;
    });
  });

  // ---- Alerts, certificate, disk, buffer (monitor-status.sh --format json) ----

  var statusNote = byId('statusUpdated');

  // Each argument is markup built by the *Html() functions below (or a
  // checklist() of escaped rows).
  function setCards(alertsMarkup, certMarkup, diskMarkup, bufferMarkup) {
    byId('alertsBody').innerHTML = alertsMarkup;
    byId('certBody').innerHTML = certMarkup;
    byId('diskBody').innerHTML = diskMarkup;
    byId('bufferBody').innerHTML = bufferMarkup;
  }

  // aria-busy tells assistive technology that the card is about to change and
  // should not be announced half-way; the view starts with it set.
  function setCardsBusy(busy) {
    ['alertsBody', 'certBody', 'diskBody', 'bufferBody'].forEach(function (id) {
      byId(id).setAttribute('aria-busy', busy ? 'true' : 'false');
    });
  }

  function checklist(rowsHtml) {
    return '<ul class="checklist">' + rowsHtml + '</ul>';
  }

  function alertsHtml(report) {
    var alerts = report.alerts || [];
    if (!alerts.length) return checklist(checkRowHtml('ok', 'No alert thresholds are crossed.'));
    return checklist(alerts.map(function (a) {
      var samples = (a.samples || []).slice(0, 3).map(function (s) {
        return '<span class="mon-sample">' + escapeHtml(s) + '</span>';
      }).join('');
      return checkRowHtml(alertSeverity(a.key), a.key + ': ' + a.message, samples);
    }).join(''));
  }

  function certHtml(report) {
    var c = report.certificate;
    if (!c) return '<p class="mon-note">No hostname is configured yet.</p>';
    if (!c.found) {
      return checklist(checkRowHtml('warn', 'No certificate file found for ' + c.host + ' in nginx/certs/.'));
    }
    var warnDays = report.thresholds && report.thresholds.certDays;
    var days = c.daysLeft;
    var status = 'ok';
    if (typeof days === 'number' && days < 0) status = 'fail';
    else if (typeof days === 'number' && typeof warnDays === 'number' && days < warnDays) status = 'warn';
    var headline = typeof days !== 'number' ? 'Expiry unknown' : days < 0 ? 'Expired ' + (-days) + ' days ago' : days + ' days left';
    return '<p class="mon-metric">' + escapeHtml(headline) + ' <span class="badge ' + BADGE_FOR[status] + '">' +
      (status === 'ok' ? 'OK' : status === 'warn' ? 'RENEW SOON' : 'EXPIRED') + '</span></p>' +
      '<p class="mon-note">Expires ' + escapeHtml(c.notAfter || 'at an unknown time') + '</p>' +
      '<p class="mon-note">Issued for ' + escapeHtml(c.host) + '</p>';
  }

  function diskHtml(report) {
    var disk = report.disk || {};
    var limit = report.thresholds && report.thresholds.diskPct;
    var fsHtml = (disk.filesystems || []).map(function (f) {
      var over = typeof f.usedPct === 'number' && typeof limit === 'number' && f.usedPct >= limit;
      return '<div class="mon-meter-row"><span>' + escapeHtml(f.mount) + ' <span class="hint">' + escapeHtml(f.path || '') + '</span></span>' +
        '<span>' + (typeof f.usedPct === 'number' ? f.usedPct + '% used' : MON_DASH) + (over ? ' <span class="badge badge-warn">OVER ' + limit + '%</span>' : '') + '</span>' +
        (typeof f.usedPct === 'number'
          ? '<meter min="0" max="100" value="' + f.usedPct + '"' + (typeof limit === 'number' ? ' high="' + limit + '"' : '') +
            ' aria-label="Disk used on ' + escapeHtml(f.mount) + '">' + f.usedPct + '%</meter>'
          : '') +
        '</div>';
    }).join('');
    var stores = (disk.stores || []).map(function (s) {
      var size = s.volume ? 'Docker volume'
        : s.inspectable === false ? 'cannot inspect from the wizard' + (s.path ? ' (mounted from ' + s.path + ')' : '')
        : s.exists === false ? 'not created yet'
        : (s.size || MON_DASH);
      return '<li><span class="badge badge-pending">DATA</span><span>' + escapeHtml(s.name) + ': ' + escapeHtml(size) + '</span></li>';
    }).join('');
    if (!fsHtml && !stores) return '<p class="mon-note">No disk information was reported.</p>';
    return fsHtml + (stores ? '<hr class="divider">' + checklist(stores) : '');
  }

  function bufferHtml(report) {
    var b = report.buffer || {};
    var t = report.thresholds || {};
    if (b.state === 'not-in-use') return '<p class="mon-note">Not in use: received documents are not buffered on the filesystem.</p>';
    if (b.state === 'not-running') return checklist(checkRowHtml('warn', 'Not available while ps-server is not running.'));
    if (b.state === 'error') return checklist(checkRowHtml('warn', 'The buffer could not be read: ' + (b.error || 'unknown error')));
    var over = (typeof t.bufferMax === 'number' && b.count > t.bufferMax) ||
      (typeof t.bufferMaxAgeHours === 'number' && typeof b.oldestAgeHours === 'number' && b.oldestAgeHours > t.bufferMaxAgeHours);
    return '<p class="mon-metric">' + escapeHtml(b.count == null ? MON_DASH : b.count) + ' waiting ' +
      '<span class="badge ' + (over ? 'badge-warn' : 'badge-ok') + '">' + (over ? 'OVER LIMIT' : 'OK') + '</span></p>' +
      '<p class="mon-note">' + (typeof b.oldestAgeHours === 'number' ? 'Oldest has waited ' + escapeHtml(b.oldestAgeHours) + ' hours.' : 'Nothing is waiting.') + '</p>' +
      (typeof t.bufferMax === 'number' ? '<p class="mon-note">Alerts above ' + escapeHtml(t.bufferMax) + ' documents or ' + escapeHtml(t.bufferMaxAgeHours) + ' hours.</p>' : '');
  }

  function renderStatus(result) {
    if (!result.ok) {
      var unavailable = '<p class="mon-note">Not available.</p>';
      setCards(checklist(checkRowHtml('warn', result.error || 'The status report could not be read.')), unavailable, unavailable, unavailable);
      statusNote.textContent = 'The checks could not be run.';
      return;
    }
    var report = result.report;
    setCards(alertsHtml(report), certHtml(report), diskHtml(report), bufferHtml(report));
    // The one sentence a screen reader hears when the four cards fill in.
    var alertCount = (report.alerts || []).length;
    statusNote.textContent = 'Checked ' + fmtTime(report.generated) + ' UTC. ' +
      (alertCount ? alertCount + (alertCount === 1 ? ' alert.' : ' alerts.') : 'No alerts.');
  }

  function loadStatus() {
    rerunBtn.disabled = true;
    setCardsBusy(true);
    statusNote.textContent = 'Checking alerts, certificate, disk and receive-back buffer…';
    return monFetch('/api/monitoring/status').then(renderStatus).catch(function (err) {
      if (err && err.expired) return;
      renderStatus({ ok: false, error: err.message });
    }).then(function () {
      setCardsBusy(false);
      rerunBtn.disabled = false;
    });
  }

  rerunBtn.addEventListener('click', loadStatus);
  loadStatus();
}

// ===========================================================================
// Logs
// ===========================================================================

function initMonitoringLogs() {
  var view = byId('logView');
  var statusEl = byId('logStatus');
  var countsEl = byId('logCounts'); // per-batch counts, hidden from screen readers
  var serviceSel = byId('logService');
  var tailSel = byId('logTail');
  var sinceSel = byId('logSince');
  var followBtn = byId('logFollow');
  var filterInput = byId('logFilter');
  var errorsOnly = byId('logErrorsOnly');
  var downloadLink = byId('logDownload');
  var reconnectBtn = byId('logReconnect');

  var es = null;
  var follow = true;
  var baseStatus = '';
  var flashTimer = null;
  var missed = 0;          // lines that arrived while the user had scrolled up
  var reconnecting = false; // the connection dropped and EventSource is retrying
  var filterTimer = null;
  var reconnectTimer = null;       // the one automatic reconnect after the service restarted
  var autoReconnectUsed = false;   // reset by anything the operator does, not by an automatic reconnect

  function current() {
    return { service: serviceSel.value, tail: Number(tailSel.value), since: sinceSel.value, follow: follow };
  }

  function filterText() {
    return filterInput.value.trim();
  }

  function filtering() {
    return Boolean(filterText()) || errorsOnly.checked;
  }

  function shownCount() {
    return view.querySelectorAll('.log-line:not([hidden])').length;
  }

  // The live region (logStatus) only changes when the state does; the counts
  // change with every batch of lines, so they sit in a separate element that
  // screen readers skip.
  function renderStatus() {
    var counts = '';
    if (filtering() && view.childElementCount) {
      counts += 'Showing ' + shownCount() + ' of ' + view.childElementCount + ' lines. ';
    }
    if (missed > 0) counts += 'Paused scrolling, ' + missed + ' new ' + (missed === 1 ? 'line' : 'lines') + '.';
    statusEl.textContent = baseStatus;
    countsEl.textContent = counts.trim();
  }

  function setStatus(text) {
    clearTimeout(flashTimer);
    baseStatus = text;
    renderStatus();
  }

  function flash(text) {
    statusEl.textContent = text;
    clearTimeout(flashTimer);
    flashTimer = setTimeout(renderStatus, 2500);
  }

  function updateFollowButton() {
    followBtn.setAttribute('aria-pressed', follow ? 'true' : 'false');
    byId('logFollowText').textContent = follow ? 'Following' : 'Follow';
    Array.prototype.forEach.call(followBtn.querySelectorAll('[data-follow]'), function (el) {
      el.hidden = el.getAttribute('data-follow') !== (follow ? 'on' : 'off');
    });
  }

  function updateDownload() {
    if (serviceSel.value) downloadLink.setAttribute('href', logDownloadUrl(current()));
  }

  function closeStream() {
    if (es) { es.close(); es = null; }
  }

  // ---- Lines ----

  function paintLine(span) {
    var text = span._raw;
    var filter = filterText();
    var visible = logLineVisible(text, span._cls, filter, errorsOnly.checked);
    span.hidden = !visible;
    if (!visible) return false;
    // Highlight only lines that actually contain the filter text.
    if (filter) span.innerHTML = highlightLine(text, filter);
    else if (span._marked) span.textContent = text;
    span._marked = Boolean(filter);
    return true;
  }

  function appendLines(lines) {
    var stick = nearBottom(view.scrollHeight, view.scrollTop, view.clientHeight);
    var frag = document.createDocumentFragment();
    var visibleNew = 0;
    lines.forEach(function (rawLine) {
      // _raw is the truncated text: filtering, copying and highlighting all
      // work on what is shown, never on a 10 MB single line.
      var line = truncateLogLine(rawLine);
      var span = document.createElement('span');
      span._raw = line;
      span._cls = classifyLogLine(line);
      span.className = 'log-line' + (span._cls ? ' log-line--' + span._cls : '');
      span.textContent = line;
      if (filtering() && paintLine(span)) visibleNew += 1;
      else if (!filtering()) visibleNew += 1;
      frag.appendChild(span);
    });
    view.appendChild(frag);
    while (view.childElementCount > LOG_LINE_CAP) view.removeChild(view.firstElementChild);

    if (stick) {
      view.scrollTop = view.scrollHeight;
      missed = 0;
    } else {
      missed += visibleNew;
    }
    renderStatus();
  }

  function repaintAll() {
    Array.prototype.forEach.call(view.children, paintLine);
    renderStatus();
  }

  // ---- Stream ----

  function clearView() {
    view.textContent = '';
    missed = 0;
  }

  function hideReconnect() {
    clearTimeout(reconnectTimer);
    reconnectBtn.hidden = true;
  }

  // auto: the one reconnect the page makes by itself after the service
  // restarted. Anything else is the operator asking, which re-arms it.
  function connect(auto) {
    closeStream();
    hideReconnect();
    if (auto !== true) autoReconnectUsed = false;
    clearView();
    reconnecting = false;
    updateDownload();
    if (!serviceSel.value) {
      setStatus('No service to show.');
      return;
    }
    setStatus('Connecting…');
    var source = new EventSource(logStreamUrl(current()));
    es = source;

    source.addEventListener('open', function () {
      if (es !== source) return;
      // After a dropped connection EventSource reconnects and the server
      // replays the tail, so start from a clean view to avoid duplicates.
      if (reconnecting) { clearView(); reconnecting = false; }
      setStatus(follow ? 'Following live output.' : 'Loading…');
    });

    source.addEventListener('lines', function (ev) {
      if (es !== source) return;
      try { appendLines(JSON.parse(ev.data).lines || []); } catch (err) { /* ignore a malformed frame */ }
    });

    // The server ended the stream (follow off, or docker exited). Close it,
    // or EventSource would reconnect and replay everything.
    source.addEventListener('end', function (ev) {
      if (es !== source) return;
      var code = null;
      try { code = JSON.parse(ev.data).code; } catch (err) { code = null; }
      closeStream();
      var count = view.childElementCount;
      if (!follow) {
        setStatus('Showing the last ' + count + (count === 1 ? ' line.' : ' lines.'));
        return;
      }
      // A followed stream only ends when the container stops (a restart, a
      // redeploy). Offer the way back, and try once by itself.
      var exit = code !== null && code !== undefined ? ' (exit ' + code + ')' : '';
      reconnectBtn.hidden = false;
      if (autoReconnectUsed) {
        setStatus('Stream ended' + exit + '.');
      } else {
        autoReconnectUsed = true;
        setStatus('Stream ended' + exit + '. Reconnecting in 3 seconds…');
        reconnectTimer = setTimeout(function () { connect(true); }, 3000);
      }
    });

    // "error" is both the browser's connection-error event (no data) and a
    // named event the server sends when docker could not be started (has
    // data). Only the second carries a message.
    source.addEventListener('error', function (ev) {
      if (es !== source) return;
      if (ev.data !== undefined) {
        var message = 'unknown error';
        try { message = JSON.parse(ev.data).message || message; } catch (err) { /* keep default */ }
        closeStream();
        setStatus('The log stream failed: ' + message);
        return;
      }
      // Anything but a permanent failure is retried by EventSource itself;
      // when it does reconnect the server replays the tail.
      if (source.readyState !== EventSource.CLOSED) reconnecting = true;
      probeAfterError(source);
    });
  }

  // A connection error tells us nothing: was the session lost, did the server
  // refuse (400/429, which EventSource cannot read), or did the network blip?
  function probeAfterError(source) {
    monFetch('/api/monitoring/services').then(function (payload) {
      if (es !== source) return;
      if (source.readyState === EventSource.CLOSED) {
        closeStream();
        var failed = composeFailedText(payload);
        setStatus(failed
          ? 'Could not open the log stream. ' + failed
          : 'Could not open the log stream - reload the page (the service may have been removed, or too many Logs tabs are open).');
      } else if (source.readyState === EventSource.CONNECTING) {
        setStatus('Disconnected — retrying…'); // already OPEN again: leave the status alone
      }
    }).catch(function (err) {
      if (err && err.expired) return; // monFetch showed the banner and stopped us
      if (es !== source) return;
      if (source.readyState !== EventSource.OPEN) setStatus('Disconnected — retrying…');
    });
  }

  monOnExpire(function () {
    closeStream();
    hideReconnect();
    setStatus('Session expired - sign in again.');
  });

  // ---- Controls ----

  function onSelectionChange() {
    try {
      history.replaceState(null, '', '/monitoring/logs?service=' + encodeURIComponent(serviceSel.value));
    } catch (err) { /* the address bar is a convenience */ }
    connect();
  }

  serviceSel.addEventListener('change', onSelectionChange);
  tailSel.addEventListener('change', connect);
  sinceSel.addEventListener('change', connect);

  // Turning Follow off only stops the live stream: the lines already on
  // screen stay. Turning it on again reloads (the server replays the tail).
  followBtn.addEventListener('click', function () {
    follow = !follow;
    updateFollowButton();
    if (follow) { connect(); return; }
    closeStream();
    hideReconnect();
    reconnecting = false;
    var count = view.childElementCount;
    setStatus('Stopped following. ' + count + (count === 1 ? ' line shown.' : ' lines shown.'));
  });

  reconnectBtn.addEventListener('click', function () { connect(); });

  filterInput.addEventListener('input', function () {
    clearTimeout(filterTimer);
    filterTimer = setTimeout(repaintAll, 150);
  });
  errorsOnly.addEventListener('change', repaintAll);

  view.addEventListener('scroll', function () {
    if (missed > 0 && nearBottom(view.scrollHeight, view.scrollTop, view.clientHeight)) {
      missed = 0;
      renderStatus();
    }
  });

  byId('logCopy').addEventListener('click', function () {
    var lines = Array.prototype.filter.call(view.children, function (s) { return !s.hidden; })
      .map(function (s) { return s._raw; });
    copyText(lines.join('\n'), function (ok) {
      flash(ok ? 'Copied ' + lines.length + (lines.length === 1 ? ' line.' : ' lines.') : 'Copying failed - select the text and copy it by hand.');
    });
  });

  window.addEventListener('pagehide', function () {
    closeStream();
    clearTimeout(reconnectTimer);
  });
  // Back/forward can restore this page from the bfcache with its stream
  // closed (pagehide) and a stale view; open a fresh one.
  window.addEventListener('pageshow', function (ev) {
    if (ev.persisted && follow) connect();
  });

  guardDownload(downloadLink, 'follow', function (message) { flash(message); });

  updateFollowButton();
  connect();
}

// ===========================================================================
// Signing activity
// ===========================================================================

function initMonitoringActivity() {
  var form = byId('activityFilters');
  var tbody = byId('activityTable').tBodies[0];
  var errBox = byId('actError');
  var summaryEl = byId('actSummary');
  var sourceBox = byId('activitySource');
  var prevBtn = byId('actPrev');
  var nextBtn = byId('actNext');
  var csvLink = byId('actCsv');
  var companySel = byId('actCompany');
  var applyBtn = byId('actApply');

  var page = 1;
  var pages = 1;
  // The filters behind the table, the CSV link and the address bar. Only
  // Apply (and the first load) sets them; whatever is typed into the form in
  // between is a draft and never reaches Previous/Next.
  var applied = null;
  var docs = [];
  var busy = false;
  var reqSeq = 0; // a response that is not the latest request's is dropped

  function readFilters() {
    return {
      from: byId('actFrom').value,
      to: byId('actTo').value,
      company: companySel.value,
      user: byId('actUser').value.trim(),
      outcome: byId('actOutcome').value
    };
  }

  function setTiles(summary) {
    byId('tileToday').textContent = String(summary.completedToday);
    byId('tile7d').textContent = String(summary.completed7d);
    byId('tile30d').textContent = String(summary.completed30d);
    byId('tileFailed').textContent = String(summary.failed);
  }

  // The company list describes the whole range; keep the operator's choice
  // even if the range changed and no longer lists it.
  function setCompanies(companies, selected) {
    var list = companies.slice();
    if (selected && list.indexOf(selected) === -1) list.push(selected);
    companySel.innerHTML = '<option value="">All companies</option>' + list.map(function (c) {
      return '<option value="' + escapeHtml(c) + '">' + escapeHtml(c) + '</option>';
    }).join('');
    companySel.value = selected || '';
  }

  function eventsHtml(doc, id) {
    var items = doc.events.map(function (ev) {
      var pill = resultPill(ev.outcome);
      return '<li><time datetime="' + escapeHtml(ev.ts) + '">' + escapeHtml(fmtTime(ev.ts)) + '</time>' +
        '<strong>' + escapeHtml(eventLabel(ev.event)) + '</strong>' + pillHtml(pill) +
        (ev.status != null ? '<span class="hint">HTTP ' + escapeHtml(ev.status) + '</span>' : '') +
        (ev.error ? '<p class="event-error">' + escapeHtml(ev.error) + '</p>' : '') + '</li>';
    }).join('');
    return '<p class="hint">Document ID <code>' + escapeHtml(doc.docid) + '</code></p><ul class="event-list" aria-label="Events for ' + escapeHtml(documentLabel(doc)) + '">' + items + '</ul>';
  }

  function rowsHtml() {
    return docs.map(function (doc, i) {
      var label = documentLabel(doc);
      return '<tr>' +
        '<td class="col-toggle"><button type="button" class="row-toggle" aria-expanded="false" aria-controls="ev-' + i + '"' +
          ' aria-label="Show events for ' + escapeHtml(label) + '" data-toggle="' + i + '"></button></td>' +
        '<td class="cell-mono">' + escapeHtml(fmtTime(doc.lastTs)) + '</td>' +
        '<td class="cell-wrap">' + escapeHtml(doc.user || MON_DASH) + '</td>' +
        '<td class="cell-wrap">' + escapeHtml(doc.company || MON_DASH) + '</td>' +
        '<td class="cell-wrap">' + escapeHtml(label) + (doc.demo ? ' <span class="pill pill-muted">demo</span>' : '') + '</td>' +
        '<td>' + pillHtml(resultPill(doc.signature)) + '</td>' +
        '<td>' + pillHtml(resultPill(doc.eseal)) + '</td>' +
        '<td>' + pillHtml(resultPill(doc.outcome)) + '</td></tr>' +
        '<tr class="event-row" id="ev-' + i + '" hidden><td colspan="8">' + eventsHtml(doc, i) + '</td></tr>';
    }).join('');
  }

  function render(result) {
    docs = result.documents || [];
    var status = result.source && result.source.status;
    var ok = status === 'ok';
    var show = activityLayout(status);
    // Without a readable log the tiles would show zeros that read as "nothing
    // was signed"; the banner explains why there is nothing to show instead.
    sourceBox.hidden = !show.banner;
    if (show.banner) sourceBox.textContent = (result.source && result.source.message) || 'The signing activity log cannot be read.';
    byId('actTiles').hidden = !show.tiles;
    form.hidden = !show.filters;
    byId('actTableWrap').hidden = !show.table;
    byId('actPager').hidden = !show.table;

    if (show.tiles) setTiles(result.summary);
    // Keep the operator's current choice (a draft may differ from the applied one).
    setCompanies(result.companies || [], companySel.value);

    if (!docs.length) {
      tbody.innerHTML = '<tr><td colspan="8" class="cell-empty">' +
        (ok ? 'No signing activity in this period.' : 'There is no signing activity to show.') + '</td></tr>';
    } else {
      tbody.innerHTML = rowsHtml();
    }

    page = result.page;
    pages = totalPages(result.total, result.pageSize);
    byId('actPage').textContent = 'Page ' + page + ' of ' + pages;
    updatePager();

    var range = result.range ? ' from ' + result.range.from + ' to ' + result.range.to : '';
    summaryEl.textContent = ok
      ? result.total + (result.total === 1 ? ' document' : ' documents') + range + '.' +
        (result.skipped ? ' ' + result.skipped + ' unreadable log ' + (result.skipped === 1 ? 'line was' : 'lines were') + ' skipped.' : '')
      : '';
  }

  function updatePager() {
    prevBtn.disabled = busy || page <= 1;
    nextBtn.disabled = busy || page >= pages;
  }

  function setBusy(value) {
    busy = value;
    applyBtn.disabled = value;
    updatePager();
  }

  // request = { filters, page } from activityApplyRequest/activityPageRequest.
  function load(request) {
    var seq = (reqSeq += 1);
    var filters = request.filters;
    setBusy(true);
    errBox.textContent = '';
    summaryEl.textContent = 'Loading…';
    return monFetch('/api/monitoring/activity?' + activityQuery(filters, request.page)).then(function (result) {
      if (seq !== reqSeq) return;
      applied = filters;
      csvLink.setAttribute('href', csvHref(filters));
      render(result);
      // Keep the address bar in step with what is on screen, so a reload or a
      // bookmarked link shows the same view.
      try {
        history.replaceState(null, '', activityPageUrl(filters, result.page));
      } catch (err) { /* the address bar is a convenience */ }
    }).catch(function (err) {
      if (seq !== reqSeq) return;
      if (err && err.expired) return;
      errBox.textContent = err.message;
      summaryEl.textContent = '';
    }).then(function () {
      if (seq === reqSeq) setBusy(false);
    });
  }

  // The form starts from the URL (a reload, a bookmark or a shared link), with
  // the default window for anything the URL does not carry validly.
  var initial = parseActivityParams(location.search, activityDefaults(new Date()));
  byId('actFrom').value = initial.filters.from;
  byId('actTo').value = initial.filters.to;
  byId('actUser').value = initial.filters.user;
  byId('actOutcome').value = initial.filters.outcome;
  setCompanies([], initial.filters.company); // the list itself arrives with the first load
  applied = readFilters();
  csvLink.setAttribute('href', csvHref(applied));

  guardDownload(csvLink, 'blob', function (message) { errBox.textContent = message; });

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    load(activityApplyRequest(readFilters()));
  });
  prevBtn.addEventListener('click', function () {
    var request = activityPageRequest(applied, page, pages, -1);
    if (request) load(request);
  });
  nextBtn.addEventListener('click', function () {
    var request = activityPageRequest(applied, page, pages, +1);
    if (request) load(request);
  });

  tbody.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('[data-toggle]') : null;
    if (!btn) return;
    var row = byId('ev-' + btn.getAttribute('data-toggle'));
    var open = btn.getAttribute('aria-expanded') === 'true';
    btn.setAttribute('aria-expanded', open ? 'false' : 'true');
    row.hidden = open;
  });

  load({ filters: applied, page: initial.page });
}

// ===========================================================================
// Diagnostics
// ===========================================================================

function initMonitoringDiagnostics(data) {
  var checks = (data && data.checks) || [];
  var runAllBtn = byId('runAll');
  var runAllStatus = byId('runAllStatus');
  var running = false;

  function runButtons() {
    return document.querySelectorAll('[data-check-run]');
  }

  function setBusy(busy) {
    running = busy;
    runAllBtn.disabled = busy;
    Array.prototype.forEach.call(runButtons(), function (b) { b.disabled = busy; });
  }

  // Resolves with the result (or null) so "Run all" can tally; never rejects.
  function runOne(id) {
    var list = byId('chk-result-' + id);
    var meta = byId('chk-meta-' + id);
    list.innerHTML = checkRowHtml('pending', 'Running…', '', 'RUNNING');
    meta.textContent = '';
    return monFetch('/api/monitoring/diagnostics/' + encodeURIComponent(id)).then(function (result) {
      list.innerHTML = (result.checks || []).map(function (c) { return checkRowHtml(c.status, c.message); }).join('');
      meta.textContent = (result.passed ? 'Passed' : 'Failed') + ' - took ' + ((result.durationMs || 0) / 1000).toFixed(1) + ' s.';
      return result;
    }).catch(function (err) {
      if (err && err.expired) { list.innerHTML = ''; return null; }
      list.innerHTML = checkRowHtml('warn', err.message);
      return null;
    });
  }

  function labelOf(id) {
    for (var i = 0; i < checks.length; i += 1) if (checks[i].id === id) return checks[i].label;
    return id;
  }

  // The result lists and their timing are not live regions (four rows per
  // check would be read out in full); this one status sentence is what a
  // screen reader hears.
  Array.prototype.forEach.call(runButtons(), function (btn) {
    btn.addEventListener('click', function () {
      if (running) return;
      var id = btn.getAttribute('data-check-run');
      setBusy(true);
      runAllStatus.textContent = 'Running ' + labelOf(id) + '…';
      runOne(id).then(function (result) {
        runAllStatus.textContent = monIsExpired() ? 'Your session has expired - sign in again.'
          : labelOf(id) + ': ' + (result ? (result.passed ? 'passed.' : 'failed.') : 'could not be run.');
        setBusy(false);
      });
    });
  });

  runAllBtn.addEventListener('click', function () {
    if (running) return;
    setBusy(true);
    var passed = 0;
    var failed = 0;
    var chain = Promise.resolve();
    checks.forEach(function (c, i) {
      chain = chain.then(function () {
        // Once the session is gone every further check would fail the same way.
        if (monIsExpired()) return null;
        runAllStatus.textContent = 'Running ' + c.label + ' (' + (i + 1) + ' of ' + checks.length + ')…';
        return runOne(c.id).then(function (result) {
          if (monIsExpired()) return;
          if (result && result.passed) passed += 1; else failed += 1;
        });
      });
    });
    chain.then(function () {
      runAllStatus.textContent = monIsExpired()
        ? 'Your session has expired - sign in again.'
        : 'Finished: ' + passed + ' passed, ' + failed + ' failed or could not run.';
      setBusy(false);
    });
  });

  // ---- Support bundle ----

  var genBtn = byId('bundleGenerate');
  var bundleStatus = byId('bundleStatus');
  var warnList = byId('bundleWarnings');
  var bundleList = byId('bundleList');
  var pollTimer = null;

  monOnExpire(function () { clearTimeout(pollTimer); });

  // Bundles are downloaded through fetch so that an expired session shows the
  // banner instead of saving an error message as a "bundle". One listener
  // covers the links the page renders and the ones added after Generate.
  bundleList.addEventListener('click', function (e) {
    var link = e.target.closest ? e.target.closest('a[download]') : null;
    if (link) runDownload(e, link, 'blob', function (message) { bundleStatus.textContent = message; });
  });

  function bundleItemHtml(b) {
    var when = b.createdAt ? ' · ' + fmtTime(b.createdAt) + ' UTC' : '';
    return '<li><a href="/api/monitoring/support-bundle/' + encodeURIComponent(b.name) + '" download>' + escapeHtml(b.name) + '</a>' +
      '<span class="hint">' + escapeHtml(fmtBytes(b.sizeBytes)) + when + '</span></li>';
  }

  function renderBundles(bundles) {
    var items = bundles.map(bundleItemHtml).join('');
    bundleList.innerHTML = items || '<li id="bundleEmpty">No support bundles have been generated yet.</li>';
  }

  // Another session (or a tab reloaded mid-run) may be generating one: wait
  // for it instead of letting the operator start a second.
  function waitForRunningBundle() {
    genBtn.disabled = true;
    bundleStatus.textContent = 'A bundle is already being generated.';
    monFetch('/api/monitoring/support-bundle').then(function (res) {
      if (res.running) { pollTimer = setTimeout(waitForRunningBundle, 5000); return; }
      renderBundles(res.bundles || []);
      bundleStatus.textContent = 'The bundle is ready.';
      genBtn.disabled = false;
    }).catch(function (err) {
      if (err && err.expired) return;
      bundleStatus.textContent = err.message;
      genBtn.disabled = false;
    });
  }

  genBtn.addEventListener('click', function () {
    genBtn.disabled = true;
    warnList.innerHTML = '';
    bundleStatus.textContent = 'Collecting logs and configuration… this can take a minute or two.';
    monFetch('/api/monitoring/support-bundle', monJson({ since: byId('bundleSince').value })).then(function (res) {
      var empty = byId('bundleEmpty');
      if (empty) empty.remove();
      bundleList.insertAdjacentHTML('afterbegin', bundleItemHtml({ name: res.name, sizeBytes: res.sizeBytes, createdAt: new Date().toISOString() }));
      var notable = (res.checks || []).filter(function (c) { return c.status !== 'ok'; });
      warnList.innerHTML = notable.map(function (c) { return checkRowHtml(c.status, c.message); }).join('');
      bundleStatus.textContent = 'Bundle ready: ' + res.name + ' (' + fmtBytes(res.sizeBytes) + ').' +
        (notable.length ? ' Some items could not be collected - see below.' : '') +
        ' Download it, send it to support, then delete it from support-bundles/.';
    }).catch(function (err) {
      if (err && err.expired) return;
      bundleStatus.textContent = err.status === 409 ? 'A bundle is already being generated.' : err.message;
    }).then(function () {
      genBtn.disabled = false;
    });
  });

  if (data && data.bundleRunning) waitForRunningBundle();
}
