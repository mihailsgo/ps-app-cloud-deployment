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

// One <li> of a .checklist: OK/WARN/FAIL badge plus a message. Line breaks in
// the message are kept (script output can be multi-line).
function checkRowHtml(status, message, extraHtml, label) {
  var badge = label || String(status || 'warn').toUpperCase();
  return '<li><span class="badge ' + (BADGE_FOR[status] || 'badge-pending') + '">' + escapeHtml(badge) + '</span>' +
    '<span>' + escapeHtml(message).replace(/\n/g, '<br>') + (extraHtml || '') + '</span></li>';
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

  function serviceRowHtml(row) {
    var st = statePill(row);
    var hp = healthPill(row);
    var svc = escapeHtml(row.service);
    var running = row.state === 'running';
    var restartOff = runActive || row.state === 'missing';
    var memTitle = row.memLimitBytes != null
      ? 'of ' + fmtBytes(row.memLimitBytes) + (row.memPct != null ? ' (' + fmtPct(row.memPct) + ')' : '')
      : '';
    return '<tr>' +
      '<th scope="row">' + svc + '</th>' +
      '<td>' + pillHtml(st) + '</td>' +
      '<td>' + pillHtml(hp) + '</td>' +
      '<td class="num">' + (running ? fmtDuration(row.uptimeSec) : MON_DASH) + '</td>' +
      '<td class="num">' + (row.restarts != null ? escapeHtml(row.restarts) : MON_DASH) + '</td>' +
      '<td class="cell-mono"' + (row.image ? ' title="' + escapeHtml(row.image) + '"' : '') + '>' + escapeHtml(row.imageTag || MON_DASH) + '</td>' +
      '<td class="num">' + fmtPct(row.cpuPct) + '</td>' +
      '<td class="num"' + (memTitle ? ' title="' + escapeHtml(memTitle) + '"' : '') + '>' + fmtBytes(row.memUsageBytes) + '</td>' +
      '<td class="cell-actions">' +
        '<a class="btn btn-secondary btn-sm" data-focus-key="logs:' + svc + '" href="/monitoring/logs?service=' + encodeURIComponent(row.service) +
          '" aria-label="Show logs of ' + svc + '">Logs</a>' +
        '<button type="button" class="btn btn-secondary btn-sm" data-restart="' + svc + '" data-focus-key="restart:' + svc + '"' +
          ' aria-label="Restart ' + svc + '"' + (restartOff ? ' disabled' : '') + '>Restart</button>' +
      '</td></tr>';
  }

  function emptyRowHtml(text) {
    return '<tr><td colspan="9" class="cell-empty">' + escapeHtml(text) + '</td></tr>';
  }

  function renderServices(payload) {
    // A refresh replaces every row; keep keyboard focus on the same control.
    var active = document.activeElement;
    var focusKey = active && tbody.contains(active) ? active.getAttribute('data-focus-key') : null;

    if (!payload.dockerAvailable) {
      tbody.innerHTML = emptyRowHtml('Docker is not reachable from the wizard.');
    } else if (!payload.services.length) {
      tbody.innerHTML = emptyRowHtml('No services were found in the compose project.');
    } else {
      tbody.innerHTML = payload.services.map(serviceRowHtml).join('');
    }

    if (focusKey) {
      var again = tbody.querySelector('[data-focus-key="' + focusKey.replace(/"/g, '\\"') + '"]');
      if (again) again.focus();
    }
    if (payload.dockerAvailable) {
      timeEl.textContent = 'Updated ' + fmtTime(payload.generatedAt) + ' UTC.';
      updated.textContent = '';
    } else {
      timeEl.textContent = '';
      updated.textContent = 'Docker is not reachable. Trying again in 10 seconds.';
    }
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
      updated.textContent = 'Could not refresh the service list: ' + err.message + ' Trying again in 10 seconds.';
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

  function checklist(rowsHtml) {
    return '<ul class="checklist">' + rowsHtml + '</ul>';
  }

  function alertsHtml(report) {
    var alerts = report.alerts || [];
    if (!alerts.length) return checklist(checkRowHtml('ok', 'No alert thresholds are crossed.'));
    return checklist(alerts.map(function (a) {
      var samples = (a.samples || []).slice(0, 3).map(function (s) {
        return '<br><span class="hint">' + escapeHtml(s) + '</span>';
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
      var size = s.volume ? 'Docker volume' : s.exists === false ? 'not created yet' : (s.size || MON_DASH);
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
    statusNote.textContent = 'Checked ' + fmtTime(report.generated) + ' UTC.';
  }

  function loadStatus() {
    rerunBtn.disabled = true;
    statusNote.textContent = 'Checking alerts, certificate, disk and receive-back buffer…';
    return monFetch('/api/monitoring/status').then(renderStatus).catch(function (err) {
      if (err && err.expired) return;
      renderStatus({ ok: false, error: err.message });
    }).then(function () {
      rerunBtn.disabled = false;
    });
  }

  rerunBtn.addEventListener('click', loadStatus);
  loadStatus();
}

// ===========================================================================
// Logs
// ===========================================================================

function initMonitoringLogs(data) {
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

  var es = null;
  var follow = true;
  var baseStatus = '';
  var flashTimer = null;
  var missed = 0;          // lines that arrived while the user had scrolled up
  var reconnecting = false; // the connection dropped and EventSource is retrying
  var filterTimer = null;

  if (data && data.selected && !serviceSel.value) serviceSel.value = data.selected;

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
    lines.forEach(function (line) {
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

  function connect() {
    closeStream();
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
      if (follow) setStatus('Stream ended' + (code !== null && code !== undefined ? ' (exit ' + code + ')' : '') + '.');
      else setStatus('Showing the last ' + count + (count === 1 ? ' line.' : ' lines.'));
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
    monFetch('/api/monitoring/services').then(function () {
      if (es !== source) return;
      if (source.readyState === EventSource.CLOSED) {
        closeStream();
        setStatus('Could not open the log stream (too many open Logs tabs?).');
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

  followBtn.addEventListener('click', function () {
    follow = !follow;
    updateFollowButton();
    connect();
  });

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

  window.addEventListener('pagehide', closeStream);

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

  var page = 1;
  var pages = 1;
  var applied = null; // the filters behind the table (and the CSV link)
  var docs = [];

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
    var ok = result.source && result.source.status === 'ok';
    sourceBox.hidden = ok;
    if (!ok) sourceBox.textContent = (result.source && result.source.message) || 'The signing activity log cannot be read.';

    setTiles(result.summary);
    setCompanies(result.companies || [], applied.company);

    if (!docs.length) {
      tbody.innerHTML = '<tr><td colspan="8" class="cell-empty">' +
        (ok ? 'No signing activity in this period.' : 'There is no signing activity to show.') + '</td></tr>';
    } else {
      tbody.innerHTML = rowsHtml();
    }

    page = result.page;
    pages = totalPages(result.total, result.pageSize);
    byId('actPage').textContent = 'Page ' + page + ' of ' + pages;
    prevBtn.disabled = page <= 1;
    nextBtn.disabled = page >= pages;

    var range = result.range ? ' from ' + result.range.from + ' to ' + result.range.to : '';
    summaryEl.textContent = ok
      ? result.total + (result.total === 1 ? ' document' : ' documents') + range + '.' +
        (result.skipped ? ' ' + result.skipped + ' unreadable log ' + (result.skipped === 1 ? 'line was' : 'lines were') + ' skipped.' : '')
      : '';
  }

  function load(targetPage) {
    var filters = readFilters();
    errBox.textContent = '';
    summaryEl.textContent = 'Loading…';
    return monFetch('/api/monitoring/activity?' + activityQuery(filters, targetPage)).then(function (result) {
      applied = filters;
      csvLink.setAttribute('href', csvHref(filters));
      render(result);
    }).catch(function (err) {
      if (err && err.expired) return;
      errBox.textContent = err.message;
      summaryEl.textContent = '';
    });
  }

  var defaults = activityDefaults(new Date());
  byId('actFrom').value = defaults.from;
  byId('actTo').value = defaults.to;
  applied = readFilters();
  csvLink.setAttribute('href', csvHref(applied));

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    load(1);
  });
  prevBtn.addEventListener('click', function () { if (page > 1) load(page - 1); });
  nextBtn.addEventListener('click', function () { if (page < pages) load(page + 1); });

  tbody.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('[data-toggle]') : null;
    if (!btn) return;
    var row = byId('ev-' + btn.getAttribute('data-toggle'));
    var open = btn.getAttribute('aria-expanded') === 'true';
    btn.setAttribute('aria-expanded', open ? 'false' : 'true');
    row.hidden = open;
  });

  load(1);
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

  Array.prototype.forEach.call(runButtons(), function (btn) {
    btn.addEventListener('click', function () {
      if (running) return;
      setBusy(true);
      runOne(btn.getAttribute('data-check-run')).then(function () { setBusy(false); });
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
        runAllStatus.textContent = 'Running ' + c.label + ' (' + (i + 1) + ' of ' + checks.length + ')…';
        return runOne(c.id).then(function (result) {
          if (result && result.passed) passed += 1; else failed += 1;
        });
      });
    });
    chain.then(function () {
      runAllStatus.textContent = 'Finished: ' + passed + ' passed, ' + failed + ' failed or could not run.';
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
