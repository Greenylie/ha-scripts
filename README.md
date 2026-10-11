# ha-scripts

Personal Home Assistant helper scripts. One folder per script, each one self-contained and droppable straight into a Home Assistant config directory.

## Why bash

This is intentionally written in bash and kept as `.sh` files. I wanted to get properly better at shell scripting, real practice on something I actually use, rather than toy exercises. Writing it in `curl` and `sed` and `while read` is the whole point, so please don't read the choice of language as an accident.

That said, nothing here depends on being shell. The scripts are essentially "make a few HTTP requests, pull a value out of the response, print it", which ports to Python or anything else pretty much line for line. Bash is just the dialect I'm currently practising.

These are also, almost certainly, a stepping stone. Some of them probably end up as proper HACS integrations once I've learned what that takes: which HTTP flows are involved, what's fragile about them, where the edge cases live. Writing the shell version first means I understand the problem before writing the polished thing, and it means I'm not publishing something I've only reasoned about on paper.

So the real purpose here is getting something working quickly for myself, iterating until it does, and sharing it in the meantime as a courtesy to anyone hitting the same wall, and as a portfolio of the work. Read it that way, not as a finished integration anyone should depend on.

## Scripts

- **[fastweb](fastweb/README.md)**: live power draw in watts from the Fastweb (Italy) customer portal.

Each script folder carries its own documentation, including setup, configuration and troubleshooting. Start there rather than here.

## Caveats

- Unofficial. They talk to portals the way a browser would, and they break whenever those portals change.
- Credentials sit in plaintext in a local `.env`. Keep the file mode tight and never commit one, the root `.gitignore` handles this for the repo.
- No automated tests. I test by watching the sensor go unavailable.
- Built for the services I use, which at the moment are Italian-only.

## License

MIT, see [LICENSE](LICENSE).