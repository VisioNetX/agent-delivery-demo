"""Orders API for Acme Outfitters, a fictional online store.

The backend that the support agent's tools call. It uses only the standard
library, so it runs on the stock python image with this file mounted from a
ConfigMap. Every request is logged, so the demo can show which calls the agent
made and which ones OpenShell blocked before they arrived.
"""

import json
import logging
import re
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("orders-api")

CUSTOMERS = {
    "C-1001": {"id": "C-1001", "name": "Dana Whitfield", "email": "dana@example.com", "tier": "gold"},
    "C-1002": {"id": "C-1002", "name": "Sam Okafor", "email": "sam@example.com", "tier": "standard"},
    "C-1003": {"id": "C-1003", "name": "Priya Raman", "email": "priya@example.com", "tier": "standard"},
}

ORDERS = {
    "A-5001": {
        "id": "A-5001", "customer_id": "C-1001", "status": "delivered",
        "placed": "2026-10-02", "delivered": "2026-10-06",
        "items": [{"sku": "TENT-2P", "name": "Ridgeline 2P Tent", "qty": 1, "price": 289.00}],
        "total": 289.00,
    },
    "A-5002": {
        "id": "A-5002", "customer_id": "C-1001", "status": "shipped",
        "placed": "2026-10-24", "carrier": "UPS", "tracking": "1Z999AA10123456784",
        "items": [{"sku": "SOCK-WOOL", "name": "Merino Hiking Socks", "qty": 3, "price": 18.00}],
        "total": 54.00,
    },
    "A-5003": {
        "id": "A-5003", "customer_id": "C-1002", "status": "delivered",
        "placed": "2026-09-12", "delivered": "2026-09-15",
        "items": [{"sku": "STOVE-1", "name": "Summit Camp Stove", "qty": 1, "price": 74.50}],
        "total": 74.50, "note": "Customer reported a damaged fuel valve.",
    },
    "A-5004": {
        "id": "A-5004", "customer_id": "C-1003", "status": "processing",
        "placed": "2026-10-28",
        "items": [{"sku": "PACK-45", "name": "Trailhead 45L Pack", "qty": 1, "price": 159.00}],
        "total": 159.00,
    },
}

REFUNDS = []

ROUTES = [
    ("GET", re.compile(r"^/healthz$"), "health"),
    ("GET", re.compile(r"^/customers/(?P<cid>[\w-]+)$"), "get_customer"),
    ("GET", re.compile(r"^/customers/(?P<cid>[\w-]+)/orders$"), "list_orders"),
    ("GET", re.compile(r"^/orders/(?P<oid>[\w-]+)$"), "get_order"),
    ("POST", re.compile(r"^/orders/(?P<oid>[\w-]+)/refunds$"), "create_refund"),
    ("GET", re.compile(r"^/refunds$"), "list_refunds"),
]


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _dispatch(self, method):
        path = self.path.split("?", 1)[0]
        for route_method, pattern, name in ROUTES:
            match = pattern.match(path)
            if match and route_method == method:
                if name != "health":
                    log.info("%s %s", method, path)
                return getattr(self, name)(**match.groupdict())
        self._send(404, {"error": "not found"})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def health(self):
        self._send(200, {"ok": True})

    def get_customer(self, cid):
        customer = CUSTOMERS.get(cid)
        self._send(200, customer) if customer else self._send(404, {"error": f"customer {cid} not found"})

    def list_orders(self, cid):
        if cid not in CUSTOMERS:
            return self._send(404, {"error": f"customer {cid} not found"})
        orders = [o for o in ORDERS.values() if o["customer_id"] == cid]
        self._send(200, {"customer_id": cid, "orders": orders})

    def get_order(self, oid):
        order = ORDERS.get(oid)
        self._send(200, order) if order else self._send(404, {"error": f"order {oid} not found"})

    def create_refund(self, oid):
        order = ORDERS.get(oid)
        if not order:
            return self._send(404, {"error": f"order {oid} not found"})
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        amount = float(body.get("amount", 0))
        if amount <= 0 or amount > order["total"]:
            return self._send(400, {"error": f"amount must be between 0 and {order['total']}"})
        refund = {
            "id": f"R-{len(REFUNDS) + 1:04d}",
            "order_id": oid,
            "amount": amount,
            "reason": body.get("reason", ""),
            "created": datetime.now(timezone.utc).isoformat(),
        }
        REFUNDS.append(refund)
        log.info("REFUND ISSUED %s", json.dumps(refund))
        self._send(201, refund)

    def list_refunds(self):
        self._send(200, {"refunds": REFUNDS})

    def log_message(self, *args):
        pass  # request logging is done in _dispatch


if __name__ == "__main__":
    log.info("orders-api listening on :8080")
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
