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
		'    def log_message(self, *a): pass' \
		'http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()' > "$T/backend.py"
	# Stands in for busybox syslogd's /dev/log: what nginx logs ends up in /var/log/messages.
	printf '%s\n' 'import socket' \
		'sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)' \
		"sock.bind('$T/log.sock')" \
		"out = open('$T/messages', 'ab', buffering=0)" \
		'while True: out.write(sock.recv(65536) + b"\n")' > "$T/syslog.py"
}

# board <with-backend|without-backend> <curl args...>: one request against nginx on the board's port 80.
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
		if [ '$backend' = with-backend ]; then python3 '$T/backend.py' >/dev/null 2>&1 & bp=\$!; sleep 0.5; fi
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

@test "a backend that is down answers in the board's envelope the dashboard can read" {
	run board without-backend http://127.0.0.1/api/system/info
	assert_line '{"success":false,"message":"Dashboard service unavailable","data":null}'
	assert_line --regexp '^502'
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
