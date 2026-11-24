#!/usr/bin/env python3
"""Tiny QMP client for spike S9 (experiments E5/E6). Spike code, not product.

  qmp.py SOCK cmd '<json command>'      run one QMP command, print the reply
  qmp.py SOCK type 'text'               type text with send-key (US layout)
  qmp.py SOCK key meta_l-r              press one key combination
  qmp.py SOCK addport PATH NAME         hot-add a virtserialport NAME whose
                                        chardev is a unix socket server at PATH
  qmp.py SOCK screendump FILE.png

SOCK is a QMP monitor of a VM started by `seemlessctl vm run` (use ctl.sock
or input.sock in the VM's run directory; qmp.sock belongs to VMProcess).
"""
import json, socket, sys, time

SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7',
           '*': '8', '(': '9', ')': '0', '_': 'minus', '+': 'equal', '{': 'bracket_left',
           '}': 'bracket_right', '|': 'backslash', ':': 'semicolon', '"': 'apostrophe',
           '~': 'grave_accent', '<': 'comma', '>': 'dot', '?': 'slash'}
PLAIN = {' ': 'spc', '\n': 'ret', '\t': 'tab', '-': 'minus', '=': 'equal', '[': 'bracket_left',
         ']': 'bracket_right', '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe',
         '`': 'grave_accent', ',': 'comma', '.': 'dot', '/': 'slash'}


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.f = self.s.makefile('rwb')
        self._read()  # greeting
        self.execute('qmp_capabilities')

    def _read(self):
        while True:
            msg = json.loads(self.f.readline())
            if 'event' not in msg:
                return msg

    def execute(self, cmd, args=None):
        req = {'execute': cmd}
        if args is not None:
            req['arguments'] = args
        self.f.write(json.dumps(req).encode() + b'\n')
        self.f.flush()
        reply = self._read()
        if 'error' in reply:
            raise SystemExit(f"{cmd}: {reply['error']}")
        return reply.get('return')

    def keys(self, names):
        self.execute('send-key', {'keys': [{'type': 'qcode', 'data': n} for n in names]})
        time.sleep(0.03)

    def type(self, text):
        for ch in text:
            if ch.isascii() and ch.isalpha():
                self.keys(['shift', ch.lower()] if ch.isupper() else [ch])
            elif ch.isdigit():
                self.keys([ch])
            elif ch in PLAIN:
                self.keys([PLAIN[ch]])
            elif ch in SHIFTED:
                self.keys(['shift', SHIFTED[ch]])
            else:
                raise SystemExit(f'cannot type {ch!r}')


def main():
    sock, verb, *rest = sys.argv[1:]
    q = QMP(sock)
    if verb == 'cmd':
        req = json.loads(rest[0])
        print(json.dumps(q.execute(req['execute'], req.get('arguments')), indent=1))
    elif verb == 'type':
        q.type(rest[0])
    elif verb == 'key':
        q.keys(rest[0].split('-'))
    elif verb == 'addport':
        path, name = rest
        q.execute('chardev-add', {'id': 's9steam', 'backend': {'type': 'socket', 'data': {
            'addr': {'type': 'unix', 'data': {'path': path}}, 'server': True, 'wait': False}}})
        q.execute('device_add', {'driver': 'virtserialport', 'chardev': 's9steam',
                                 'name': name, 'id': 's9steamport'})
        print(f'added virtserialport {name} on {path}')
    elif verb == 'screendump':
        q.execute('screendump', {'filename': rest[0], 'format': 'png'})
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
