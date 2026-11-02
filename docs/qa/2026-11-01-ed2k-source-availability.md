# Reported eD2K source availability

The user reported a task at 0% and confirmed its displayed peer/source count was zero. The current eD2K row reuses the BT peer label, but the native value is `TransferStatus.NumPeers`, a count of discovered peer candidates, not proof of established payload connections. Zero means no candidates are currently registered.

An independent host probe used the same pinned engine and the reported file hash/64-bit size. Both its target and control transfers were paused; server/Kad source lookup ran, but no media payload was requested or downloaded.

At the end of the 20-second target/control query:

- 11 configured server entries, 11 TCP connections, 10 completed server handshakes.
- The reported 5,263,316,776-byte file: zero returned source candidates.
- A separate previously used control file: two returned source candidates. Debug responses explicitly included `FoundFileSources count=2` for the control and `count=0` for the target.

An earlier 30-second target-only query also returned zero candidates. This supports current source unavailability in the queried discovery network, while demonstrating that server discovery/request/response decoding can return sources. It does not establish permanent invalidity, availability through every server/network, or the live state of the phone's network. Kad table counts include cached contacts and are not presented as verified active peers.

The task can remain saved for later retry. No runtime download state was reset or modified by this probe. The user's clarification about zero was answered; no automatic download or task resume was performed on the phone.
