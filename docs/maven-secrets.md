# Native secrets for Maven settings

MakeVN resolves `${env.NAME}` references in Maven user and installation settings
immediately before invoking Maven. An existing nonempty environment variable wins.
Missing variables are read from the native store under service
`makevn.maven.environment`, account `NAME`. No secret values belong in
`.makevn/config`, command arguments, source control or agent chat.

On macOS, use Keychain Access to add a generic password with the service/name
`makevn.maven.environment` and the account matching the variable name. Enter its
password in the native application. MakeVN uses `security find-generic-password`
and honors the keychain's access controls. Unlock the login keychain and authorize
access locally when prompted.

On Linux, install libsecret's `secret-tool` and run this in your own terminal:

```sh
secret-tool store --label='MakeVN Maven credential' service makevn.maven.environment account REPOSITORY_TOKEN
```

Enter the value at the native prompt. A running, unlocked Secret Service is
required. Headless CI should supply the variable from its existing CI secret
facility. Other operating systems can also supply inherited environment variables;
native lookup is unavailable there.

MakeVN inspects the default `~/.m2/settings.xml`, an installation settings file
located through `MAVEN_HOME` or the installed `mvn` executable, and explicit
`-s`/`--settings` and `-gs`/`--global-settings` selections. Arguments in
`.mvn/maven.config` and `MAVEN_ARGS` are considered before explicit command
arguments. A wrapper's private downloaded installation settings cannot be located
before the wrapper starts; use explicit global settings for those references.
Custom `user.home` overrides and Maven 4 project settings are not inspected yet.

Resolved values exist only in the Maven child environment and in MakeVN memory.
MakeVN replaces their exact values in captured Maven output with `[REDACTED]`.
Build plugins still control files they create; do not configure plugins to write
credentials to reports. No setup operation reads secret values into chat.

Missing variables or unavailable stores stop execution with the variable name and
setup guidance. Once Maven runs, its exit code and HTTP diagnostics are preserved:
401 and 403 remain distinct server responses. A response alone does not prove
whether a credential is absent, expired or lacks repository permission.
