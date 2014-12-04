# rubysockd

This gem is my attempt at creating a simple boilerplate ruby daemon which interfaces over TCP or unix sockets, which can be forked and built upon whenever I need to create a persistant, single-threaded daemon with a simple API.

Hopefully others will find this simple exercise useful.

The commands are simple:

```bash
$ rubysockd start		# start the daemon
$ rubysockd stop		# stop the daemon
$ rubysockd restart		# stop, then start the daemon
```

--------

Issuing `rubysockd` without a command will start the server without deamonizing it for easy debugging.

```bash
$ rubysockd
Starting rubysockd server...
Awaiting connections...
```

--------

Any other command will run as a client and attempt to send a message to the daemon, printing the response to stdout.

```bash
$ rubysockd get foo
bar
```

--------

## Additional arguments

Use help command for reference to custom pid, user, group, and socket settings.

```bash
$ rubysockd --help
...
```

--------

Note the socket can be a Unix socket, or a TCP connection.  Any socket which starts with a '/' will be treated as a Unix socket.  Remember if you use a non-default socket you must provide the same socket argument when issuing commands to a running daemon.

--------

