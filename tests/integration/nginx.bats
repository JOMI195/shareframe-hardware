# nginx with the image's config: the dashboard build, /api to the backend, captive-portal
# probes, and the board's JSON envelope when the backend is down.
load ../support/common
load ../support/ns

setup() {
	host_setup
	mkdir -p "$T/nginx" "$T/share/dashboard-frontend/assets" "$T/nginx-tmp"
	cp "$OVERLAY"/etc/nginx/* "$T/nginx/"
	cp /etc/nginx/mime.types "$T/nginx/"
	cp -r "$OVERLAY/usr/share/shareframe/errors" "$T/share/"
	echo '<html>dashboard</html>' > "$T/share/dashboard-frontend/index.html"
	echo 'console.log(1)' > "$T/share/dashboard-frontend/assets/app.js"
	printf '%s\n' 'import http.server' \
		'class H(http.server.BaseHTTPRequestHandler):' \
		'    def do_GET(self):' \
		'        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()' \
		'        self.wfile.write(b"{\"success\":true,\"data\":{\"path\":\"" + self.path.encode() + b"\"}}")' \
		'    def do_POST(self):' \
		'        n = int(self.headers["Content-Length"] or 0); self.rfile.read(n)' \
		'        enc = self.headers.get("Content-Encoding") or "none"' \
		'        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()' \
		'        self.wfile.write(("{\"encoding\":\"%s\",\"length\":%d}" % (enc, n)).encode())' \
		'    def log_message(self, *a): pass' \
		'http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()' > "$T/backend.py"
	# Like the board's backend: an HTTP/1.1 answer without "Connection: close", one request per
	# connection, and whatever else arrives on it is dropped when the socket closes.
	printf '%s\n' 'import http.server, time' \
		'class H(http.server.BaseHTTPRequestHandler):' \
		'    protocol_version = "HTTP/1.1"' \
		'    def handle(self): self.handle_one_request(); time.sleep(0.3)' \
		'    def do_POST(self):' \
		'        self.rfile.read(int(self.headers["Content-Length"] or 0))' \
		'        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")' \
		'    def log_message(self, *a): pass' \
		'http.server.ThreadingHTTPServer(("127.0.0.1", 8080), H).serve_forever()' > "$T/one-shot-backend.py"
	# Stands in for busybox syslogd's /dev/log: what nginx logs ends up in /var/log/messages.
	printf '%s\n' 'import socket' \
		'sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)' \
		"sock.bind('$T/log.sock')" \
		"out = open('$T/messages', 'ab', buffering=0)" \
		'while True: out.write(sock.recv(65536) + b"\n")' > "$T/syslog.py"
}

# board <with-backend|one-shot-backend|without-backend> <curl args...>: one request against nginx on the board's port 80.
board() {
	local backend=$1
	shift
	in_ns "
		mount --bind '$T/nginx' /etc/nginx
		mount --bind '$T/share' /usr/share/shareframe
		mount -t tmpfs run /run && mkdir -p /run/shareframe/ssdp
		echo '<root/>' > /run/shareframe/ssdp/description.xml
		mkdir -p /tmp/nginx
		bp=
		case '$backend' in
			with-backend) python3 '$T/backend.py' >/dev/null 2>&1 & bp=\$!; sleep 0.5 ;;
			one-shot-backend) python3 '$T/one-shot-backend.py' >/dev/null 2>&1 & bp=\$!; sleep 0.5 ;;
		esac
		python3 '$T/syslog.py' & sp=\$!
		sed -i 's#unix:/dev/log#unix:$T/log.sock#' /etc/nginx/nginx.conf
		sleep 0.3
		nginx -c /etc/nginx/nginx.conf -g 'daemon on;' 2>/dev/null
		curl -s -m 5 -o - -w '\n%{http_code} %{redirect_url}\n' $* || true
		nginx -s stop 2>/dev/null; [ -z \"\$bp\" ] || kill \$bp
		sleep 0.3; kill \$sp
		sleep 0.2
	" 3>&-
}

@test "the dashboard and its client routes are the SPA" {
	run board without-backend http://127.0.0.1/
	assert_line '<html>dashboard</html>'
	assert_line --regexp '^200'
	run board without-backend http://127.0.0.1/network/
	assert_line '<html>dashboard</html>'
	run board without-backend http://127.0.0.1/assets/app.js
	assert_line 'console.log(1)'
}

@test "/api reaches the backend with its path" {
	run board with-backend http://127.0.0.1/api/system/info
	assert_line '{"success":true,"data":{"path":"/api/system/info"}}'
	assert_line --regexp '^200'
}

# The backend inflates a gzip request body without a limit; nginx keeps both the size and the encoding away.
@test "an oversized request body never reaches the backend" {
	head -c 100000 /dev/zero > "$T/big.bin"
	run board with-backend -X POST --data-binary @"$T/big.bin" http://127.0.0.1/api/auth/login
	assert_line --regexp '^413'
}

@test "a request body's content encoding is not passed to the backend" {
	run board with-backend -X POST -H Content-Encoding:gzip -d x http://127.0.0.1/api/auth/login
	assert_line '{"encoding":"none","length":1}'
}

# A POST is never retried by nginx, so one sent down a connection the backend already dropped is a 502.
@test "posts in a row reach a backend that serves one request per connection" {
	run board one-shot-backend -X POST -d x http://127.0.0.1/api/auth/login http://127.0.0.1/api/auth/login
	refute_line --regexp '^502'
	assert_equal "$(grep -c '^200' <<<"$output")" 2
}

@test "a backend that is down answers in the board's envelope the dashboard can read" {
	run board without-backend http://127.0.0.1/api/system/info
	assert_line '{"success":false,"message":"Dashboard service unavailable","data":null}'
	assert_line --regexp '^502'
}

# A page on another name that rebinds its DNS to the board must not reach the API; a router's DNS name for
# the board still finds the dashboard, at the address it came in on.
@test "only the board's own names reach the dashboard, other names are sent to its address" {
	for host in evil.example shareframe-board-1a2b.fritz.box; do
		run board with-backend -H "Host:$host" http://127.0.0.1/api/system/info
		assert_line "302 http://127.0.0.1/"
		refute_line --partial '"path"'
	done
	for host in shareframe-board-1A2B.local shareframe-board.local localhost 10.55.0.1 127.0.0.1; do
		run board with-backend -H "Host:$host" http://127.0.0.1/api/system/info
		assert_line '{"success":true,"data":{"path":"/api/system/info"}}'
	done
}

@test "the phones' captive-portal probes open the dashboard" {
	for probe in generate_204 hotspot-detect.html connecttest.txt; do
		run board without-backend "http://127.0.0.1/$probe"
		assert_line --regexp "^302 http://127.0.0.1/$"
	done
}

@test "the SSDP description is served from /run" {
	run board without-backend http://127.0.0.1/ssdp/description.xml
	assert_line '<root/>'
}

# The system log page and the support package read /var/log/messages; nginx's own errors must land there.
@test "a backend that is down is logged to syslog, where the system log and diagnostics read it" {
	run board without-backend http://127.0.0.1/api/system/info
	run cat "$T/messages"
	assert_output --partial 'nginx'
	assert_output --partial 'connect() failed'
	assert_output --partial '/api/system/info'
}
