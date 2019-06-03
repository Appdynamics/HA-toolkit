# HA
Appdynamics HA Controller provisioning subsystem

## Non-developer installation & use
* HA Toolkit *must* be installed from `HA.shar`
* Download HA.shar from https://github.com/Appdynamics/HA-toolkit/releases/latest or clone this repository and then run `make` to build a fresh HA.shar

## v4.5.6+ controllers
* ensure you download and install at least HA Toolkit version 3.48 for v4.5.6+ controllers

## v4.3 controllers
* ensure you download and install at least HA Toolkit version 3.26 for v4.3 controllers

## Documentation
See [README.txt](README.txt) and https://docs.appdynamics.com/display/PRO42/Using+the+High+Availability+(HA)+Toolkit

## Issues
please feel free to add issues to the issues list, and the development team
will triage and prioritize the issues as appropriate.

## Release Discipline

there is only one master tree, keep it clean.  if you pushed a broken file, push a fix quickly.

when ready to cut a release, make sure you update VERSION and Release Notes

Release_Notes should contain a substantive mention of every change in this delta.

I like to also rev the RCS tag in every file I touch.  this is a bit atavistic, I know, but it is much more meaningful than a git guid or some other madness. tools/upver.sh is handy for this.  it's not a perfect tool, but it does the job most of the time.

Revision numbers are of the form x.y[.z].
* increment the minor number y when fixing bugs or adding features.
* increment major number x and zero the minor y when large architectural changes are implicated
* point releases z should only be employed to fix a bad release.

to cut a release, build the HA.shar using the makefile, create a new tag equal to the VERSION, and summarize the release with a pithy name. paste the release notes change to the description.
