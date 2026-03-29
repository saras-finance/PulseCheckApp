import yaml
import requests
import time
import os
import json
from datetime import datetime, timedelta
from concurrent.futures import ThreadPoolExecutor
from sendgrid import SendGridAPIClient
from sendgrid.helpers.mail import Mail
from jinja2 import Template
from feedgen.feed import FeedGenerator

# --- Configuration Loader ---
def load_yaml(path):
    if not os.path.exists(path): return {}
    with open(path, "r") as f:
        return yaml.safe_load(f)

# --- Alert Providers ---

class AlertProvider:
    def send(self, data, config):
        raise NotImplementedError

class PushoverAlert(AlertProvider):
    def send(self, data, config):
        c = config.get("providers", {}).get("pushover", {})
        if not c.get("enabled"): return
        user_key = os.environ.get(c.get("user_key_env"))
        token = os.environ.get(c.get("token_env"))
        if not user_key or not token: return
        message = f"🔴 {data['group']} - {data['name']} is DOWN\nStatus: {data['status']}" if data['status'] else f"Error: {data['error']}"
        try:
            requests.post("https://api.pushover.net/1/messages.json", data={
                "token": token, "user": user_key, "message": message,
                "priority": 1 if data.get("critical") else 0
            })
        except Exception as e: print(f"🚨 Pushover Error: {e}")

class SendGridAlert(AlertProvider):
    def send(self, data, config):
        c = config.get("providers", {}).get("sendgrid", {})
        if not c.get("enabled"): return
        api_key = os.environ.get(c.get("api_key_env"))
        if not api_key: return
        message = Mail(
            from_email=c.get("from_email"),
            to_emails=c.get("to_email"),
            subject=f"🔴 PulseCheck Alert: {data['name']} is DOWN",
            plain_text_content=f"Service: {data['name']} ({data['group']}) failed.\nTime: {data['timestamp']}"
        )
        try:
            sg = SendGridAPIClient(api_key)
            sg.send(message)
        except Exception as e: print(f"🚨 SendGrid Error: {e}")

class WebhookAlert(AlertProvider):
    def send(self, data, config):
        c = config.get("providers", {}).get("webhook", {})
        if not c.get("enabled"): return
        url = os.environ.get(c.get("url_env"))
        if not url: return
        headers = {k: v.replace("${ALERT_WEBHOOK_BEARER_TOKEN}", os.environ.get("ALERT_WEBHOOK_BEARER_TOKEN", "")) for k, v in c.get("headers", {}).items()}
        payload = {k: v.format(**data) if isinstance(v, str) else v for k, v in c.get("payload_template", {}).items()}
        try:
            requests.request(c.get("method", "POST"), url, headers=headers, json=payload, timeout=10)
        except Exception as e: print(f"🚨 Webhook Error: {e}")

# --- Monitoring Core ---

class Monitor:
    def __init__(self):
        self.endpoints_config = load_yaml("endpoints.yaml")
        self.alerts_config = load_yaml("alerts.yaml")
        self.providers = [PushoverAlert(), SendGridAlert(), WebhookAlert()]
        self.results = {}
        self.history_file = "history.json"
        self.history = self.load_history()

    def load_history(self):
        if os.path.exists(self.history_file):
            with open(self.history_file, "r") as f:
                return json.load(f)
        return {}

    def save_history(self):
        history_days = self.endpoints_config.get("history_days", 90)
        cutoff = datetime.now().timestamp() - (history_days * 24 * 3600)
        for url in self.history:
            self.history[url] = [h for h in self.history[url] if h['t'] > cutoff]
        with open(self.history_file, "w") as f:
            json.dump(self.history, f)

    def check_endpoint(self, endpoint, group_name):
        name, url = endpoint.get("name"), endpoint.get("url")
        print(f"🔍 Checking {name}...")
        result = {"name": name, "url": url, "is_up": False, "elapsed": 0, "status": None, "error": None}
        start = time.time()
        try:
            response = requests.get(url, timeout=endpoint.get("timeout", 10))
            result["elapsed"] = (time.time() - start) * 1000
            result["status"] = response.status_code
            result["is_up"] = 200 <= response.status_code < 300
            if not result["is_up"]: self.notify(name, group_name, result["status"], None, endpoint.get("critical", False))
        except Exception as e:
            result["error"] = str(e)
            self.notify(name, group_name, None, str(e), endpoint.get("critical", False))
        # Record to history: t=time, s=success, r=response_time, c=code
        if url not in self.history: self.history[url] = []
        self.history[url].append({
            "t": time.time(), 
            "s": result["is_up"], 
            "r": round(result["elapsed"], 2), 
            "c": result["status"]
        })

        # Add limited history to result for template (last 50 checks)
        result["history_details"] = self.history[url][-50:]
        result["uptime_bars"] = self.calculate_bars(url)
        result["uptime_pct"] = self.calculate_uptime(url)
        
        if group_name not in self.results: self.results[group_name] = []
        self.results[group_name].append(result)

    def calculate_bars(self, url):
        bars = []
        now = datetime.now()
        hist = self.history.get(url, [])
        for i in range(89, -1, -1):
            day_start = (now - timedelta(days=i)).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
            day_end = day_start + 86400
            day_checks = [h for h in hist if day_start <= h['t'] < day_end]
            if not day_checks: bars.append("none")
            elif any(not h['s'] for h in day_checks): bars.append("down")
            else: bars.append("up")
        return bars

    def calculate_uptime(self, url):
        hist = self.history.get(url, [])
        if not hist: return 100.0
        ups = len([h for h in hist if h['s']])
        return (ups / len(hist)) * 100

    def notify(self, name, group, status, error, critical):
        data = {"name": name, "group": group, "status": status, "error": error, "critical": critical, "timestamp": datetime.now().isoformat()}
        for provider in self.providers: provider.send(data, self.alerts_config)

    def generate_status_page(self):
        with open("status_template.html", "r") as f:
            template = Template(f.read())
        html = template.render(results=self.results, last_updated=datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC"))
        with open("../index.html", "w") as f: f.write(html)

    def generate_rss(self):
        fg = FeedGenerator()
        fg.id("https://saras-finance.github.io/PulseCheckApp/")
        fg.title("Saras Finance - PulseCheck Status")
        fg.link(href="https://saras-finance.github.io/PulseCheckApp/", rel="alternate")
        fg.description("Real-time health status for Saras Finance services")
        for group, eps in self.results.items():
            for ep in eps:
                if not ep["is_up"]:
                    fe = fg.add_entry()
                    fe.id(f"{ep['url']}-{time.time()}")
                    fe.title(f"OUTAGE: {ep['name']} is DOWN")
                    fe.content(f"Service {ep['name']} in {group} reported status {ep['status'] or 'Error'}")
        fg.rss_file("../rss.xml")

    def run(self):
        groups = self.endpoints_config.get("groups", [])
        with ThreadPoolExecutor(max_workers=10) as executor:
            for group in groups:
                g_name = group.get("name")
                for ep in group.get("endpoints", []): executor.submit(self.check_endpoint, ep, g_name)
        self.save_history()
        self.generate_status_page()
        self.generate_rss()

if __name__ == "__main__":
    Monitor().run()
