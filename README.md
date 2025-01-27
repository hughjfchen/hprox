## hprox

[![CircleCI](https://circleci.com/gh/bjin/hprox.svg?style=shield)](https://circleci.com/gh/bjin/hprox)
[![CirrusCI](https://api.cirrus-ci.com/github/bjin/hprox.svg)](https://cirrus-ci.com/github/bjin/hprox)
[![Depends](https://img.shields.io/hackage-deps/v/hprox.svg)](https://packdeps.haskellers.com/feed?needle=hprox)
[![Release](https://img.shields.io/github/release/bjin/hprox.svg)](https://github.com/bjin/hprox/releases)
[![Hackage](https://img.shields.io/hackage/v/hprox.svg)](https://hackage.haskell.org/package/hprox)
[![License](https://img.shields.io/github/license/bjin/hprox.svg)](https://github.com/bjin/hprox/blob/master/LICENSE)

`hprox` is a lightweight HTTP/HTTPS proxy server.

### Features

* Basic HTTP proxy functionality.
* Simple password authentication.
* TLS encryption (requires a valid certificate). Supports TLS 1.3 and HTTP/2, also known as SPDY Proxy.
* TLS SNI validation (blocks all clients with invalid domain name).
* Provide PAC file for easy client side configuration (supports Chrome and Firefox).
* Websocket redirection (compatible with [my-plugin](https://github.com/shadowsocks/my-plugin)).
* Reverse proxy support (redirect requests to a fallback server).
* DNS-over-HTTPS (DoH) support.
* [naiveproxy](https://github.com/klzgrad/naiveproxy) compatible [padding](https://github.com/klzgrad/naiveproxy/#padding-protocol-an-informal-specification) (HTTP Connect proxy).
* HTTP/3 (QUIC) support (`h3` protocol).
* Implemented as a middleware, compatible with any Haskell Web Application built with `wai` interface.
  See [library documents](https://hackage.haskell.org/package/hprox) for details.

### Installation

`hprox` should build and work on all unix-like OS with `ghc` support, as well as Windows.

[stack](https://docs.haskellstack.org/en/stable/README/#how-to-install) is recommended to build `hprox`.

```sh
stack setup
stack install
```

Alternatively, you also can use the statically linked binary for the [latest release](https://github.com/bjin/hprox/releases).

### Usage

Use `hprox --help` to list options with detailed explanation.

* To run `hprox` on port 8080, with simple password authentication:

```sh
echo "user:pass" > userpass.txt
hprox -p 8080 -a userpass.txt
```

* To run `hprox` with TLS encryption on port 443, with certificate of `example.com` obtained with [acme.sh](https://acme.sh/):

```sh
hprox -p 443 -s example.com:$HOME/.acme.sh/example.com/fullchain.cer:$HOME/.acme.sh/example.com/example.com.key
```

Browsers can be configured with PAC file URL `https://example.com/.hprox/config.pac`.

* To work with `my-plugin`, with fallback page to [ubuntu archive](http://archive.ubuntu.com/):

```sh
my-plugin -server -localPort 8080 -mode websocket -host example.com -remotePort xxxx
hprox -p 443 -s example.com:fullchain.pem:privkey.pem --ws 127.0.0.1:8080 --rev archive.ubuntu.com:80
```

Clients will be able to connect with plugin option `tls;host=example.com`.

* Enable HTTP/3 (QUIC) on UDP port 8443, enable DoH support (redirect to 8.8.8.8), and add `naiveproxy` compatible padding:

```sh
hprox -p 443 -q 8443 -s example.com:fullchain.pem:privkey.pem -a userpass.txt --naive --doh 8.8.8.8
```

Then DoH can be accessed at `https://example.com/dns-query`.

### Known Issue

* Passwords are currently stored in plain text, please set permission accordingly and
  avoid using existing password.
* HTTP/3 currently only works on the first domain as specified by `-s/--tls`, also SNI
  validation is unavailable as well.

### License

`hprox` is licensed under the Apache license. See LICENSE file for details.
