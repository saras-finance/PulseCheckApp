import yaml
import requests
import time
import os
import json
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
from sendgrid import SendGridAPIClient
from sendgrid.helpers.mail import Mail
from jinja2 import Template

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

        message = f"🔴 {data['group']} - {data['name']} is DOWN\n"
        message += f"Status: {data['status']}" if data['status'] else f"Error: {data['error']}"

        try:
            requests.post("https://api.pushover.net/1/messages.json", data={
                "token": token, "user": user_key, "message": message,
                "priority": 1 if data.get("critical") else 0
            })
            print(f"🔔 Pushover sent for {data['name']}")
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
            subject=f"🔴 PulseCheck: {data['name']} is DOWN",
            plain_text_content=f"Service: {data['name']} in {data['group']} failed.\nStatus: {data['status']}\nError: {data['error']}\nTime: {data['timestamp']}"
        )
        try:
            sg = SendGridAPIClient(api_key)
            sg.send(message)
            print(f"📧 SendGrid email sent for {data['name']}")
        except Exception as e: print(f"🚨 SendGrid Error: {e}")

class WebhookAlert(AlertProvider):
    def send(self, data, config):
        c = config.get("providers", {}).get("webhook", {})
        if not c.get("enabled"): return
        
        url = os.environ.get(c.get("url_env"))
        if not url: return

        headers = {}
        for k, v in c.get("headers", {}).items():
            if "${" in v:
                env_key = v.split("${")[1].split("}")[0]
                headers[k] = v.replace(f"${{{env_key}}}", os.environ.get(env_key, ""))
            else:
                headers[k] = v

        payload = {k: v.format(**data) if isinstance(v, str) else v for k, v in c.get("payload_template", {}).items()}
        
        try:
            requests.request(c.get("method", "POST"), url, headers=headers, json=payload, timeout=10)
            print(f"🔗 Webhook triggered for {data['name']}")
        except Exception as e: print(f"🚨 Webhook Error: {e}")

# --- Monitoring Core ---

class Monitor:
    def __init__(self):
        self.endpoints_config = load_yaml("endpoints.yaml")
        self.alerts_config = load_yaml("alerts.yaml")
        self.providers = [PushoverAlert(), SendGridAlert(), WebhookAlert()]
        self.results = {} # group -> [endpoints]
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
        
        # Prune old history
        for url in self.history:
            self.history[url] = [h for h in self.history[url] if h['t'] > cutoff]
            
        with open(self.history_file, "w") as f:
            json.dump(self.history, f)

    def check_endpoint(self, endpoint, group_name):
        name = endpoint.get("name")
        url = endpoint.get("url")
        print(f"🔍 Checking {name} ({url})...")
        
        result = {"name": name, "url": url, "is_up": False, "elapsed": 0, "status": None, "error": None}
        
        start = time.time()
        try:
            response = requests.get(url, timeout=endpoint.get("timeout", 10))
            elapsed = (time.time() - start) * 1000
            code = response.status_code
            is_up = 200 <= code < 300

            result["is_up"] = is_up
            result["elapsed"] = elapsed
            result["status"] = code

            if is_up:
                print(f"✅ {name} is UP ({code}) - {elapsed:.2f}ms")
            else:
                print(f"❌ {name} is DOWN ({code})")
                self.notify(name, group_name, code, None, endpoint.get("critical", False))
        except Exception as e:
            result["error"] = str(e)
            print(f"❌ {name} error: {e}")
            self.notify(name, group_name, None, str(e), endpoint.get("critical", False))
        
        # Record to history
        if url not in self.history: self.history[url] = []
        self.history[url].append({"t": time.time(), "s": result["is_up"]})
        
        # Add history to result for template
        result["history"] = self.history[url]
        
        if group_name not in self.results: self.results[group_name] = []
        self.results[group_name].append(result)

    def notify(self, name, group, status, error, critical):
        data = {
            "name": name, "group": group, "status": status,
            "error": error, "critical": critical,
            "timestamp": datetime.now().isoformat()
        }
        for provider in self.providers:
            provider.send(data, self.alerts_config)

    def generate_status_page(self):
        if not os.path.exists("status_template.html"): return
        with open("status_template.html", "r") as f:
            template = Template(f.read())
        
        html = template.render(
            results=self.results,
            last_updated=datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
        )
        with open("index.html", "w") as f:
            f.write(html)
        print("📝 Status page generated: index.html")

    def run(self):
        groups = self.endpoints_config.get("groups", [])
        with ThreadPoolExecutor(max_workers=10) as executor:
            for group in groups:
                g_name = group.get("name")
                for endpoint in group.get("endpoints", []):
                    executor.submit(self.check_endpoint, endpoint, g_name)
        
        # Save historical data
        self.save_history()
        # Generate the UI
        self.generate_status_page()

if __name__ == "__main__":
    Monitor().run()
