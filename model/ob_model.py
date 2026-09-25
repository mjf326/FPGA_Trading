"""Golden reference model for the FPGA order book.

Pure-Python, deliberately simple, and independent of the RTL structure: dicts of
price -> deque of resting orders. Must match rtl/order_book.sv behaviour:
  * price-time priority, trades at the resting (maker) price
  * ADD with qty 0, ADD with a live id, CANCEL of a non-live id -> reject
  * unknown message types are dropped by the feed handler (no event)
"""
from collections import deque

ADD, CANCEL = 1, 2
BUY, SELL = 0, 1
ID_W, PRICE_W, QTY_W = 10, 8, 16

EV_TRADE, EV_REJECT = 1, 2


def encode_msg(mtype, side, oid, price, qty):
    """Pack one 64-bit input message (see rtl/feed_handler.sv)."""
    return (mtype << 60) | (side << 59) | (oid << 49) | (price << 41) | (qty << 25)


def encode_event(kind, a, b, price, qty):
    """Pack one 64-bit output event. Trade: a=maker, b=taker. Reject: a=id, b=0."""
    return (kind << 60) | (a << 50) | (b << 40) | (price << 32) | (qty << 16)


class OrderBook:
    def __init__(self):
        self.bids = {}   # price -> deque[[id, qty]]
        self.asks = {}
        self.live = {}   # id -> (side, price)

    def _side_book(self, side):
        return self.bids if side == BUY else self.asks

    def process(self, mtype, side, oid, price, qty):
        """Returns a list of packed events."""
        if mtype == ADD:
            return self._add(side, oid, price, qty)
        if mtype == CANCEL:
            return self._cancel(oid)
        return []  # dropped

    def _add(self, side, oid, price, qty):
        if qty == 0 or oid in self.live:
            return [encode_event(EV_REJECT, oid, 0, 0, 0)]
        events = []
        opp = self._side_book(1 - side)
        while qty > 0 and opp:
            best = min(opp) if side == BUY else max(opp)
            if (side == BUY and best > price) or (side == SELL and best < price):
                break
            q = opp[best]
            maker = q[0]
            fill = min(qty, maker[1])
            events.append(encode_event(EV_TRADE, maker[0], oid, best, fill))
            qty -= fill
            maker[1] -= fill
            if maker[1] == 0:
                q.popleft()
                del self.live[maker[0]]
                if not q:
                    del opp[best]
        if qty > 0:
            book = self._side_book(side)
            book.setdefault(price, deque()).append([oid, qty])
            self.live[oid] = (side, price)
        return events

    def _cancel(self, oid):
        if oid not in self.live:
            return [encode_event(EV_REJECT, oid, 0, 0, 0)]
        side, price = self.live.pop(oid)
        book = self._side_book(side)
        q = book[price]
        for i, o in enumerate(q):
            if o[0] == oid:
                del q[i]
                break
        if not q:
            del book[price]
        return []

    def best_bid(self):
        return max(self.bids) if self.bids else None

    def best_ask(self):
        return min(self.asks) if self.asks else None
