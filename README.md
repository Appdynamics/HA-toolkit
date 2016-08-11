# HA
Appdynamics HA Controller provisioning subsystem

## Documentation
See [README.txt](README.txt) and https://docs.appdynamics.com/display/PRO42/Using+the+High+Availability+(HA)+Toolkit

## Contributing

### Use HubFlow to manage development branches and releases

Git Flow automates [a number of excellent conventions for managing branches, merges, and releases](http://nvie.com/posts/a-successful-git-branching-model/).  HubFlow is a GitHub-aware fork of the original Git Flow project:

* Easily installed on Mac OS X via homebrew 
* Documentation: http://datasift.github.io/gitflow/

The Git Flow / Hubflow workflow maintains a pair of branches: `develop` and `master`.  `develop` contains every merged feature and bug fix.  `master` only contains released, production-ready code.  Bug fixes or features are branched from develop and then merged back in.

***Please note that only Curt Mayer, the project architect, has push privileges to the `develop` and `master` branches in this repository.***  To get your features and fixes merged into `develop` and released into `master`, please follow the procedures below.

#### Getting started with HA toolkit development

##### AppDynamics GitHub organization members:

* Install hubflow \(`brew install hubflow` on Macs with [Homebrew](http://brew.sh) installed, follow the instructions [here](https://github.com/datasift/gitflow) for other platforms.\)
* Clone this repo from GitHub with SSH
* Change directories into your clone of the HA-toolkit repo and run `git hf init`

##### Others:

* Fork this repository on GitHub
* Clone your forked repository to your development machine.

#### Common operations

Please see [Datasift's excellent tutorial on HubFlow](http://datasift.github.io/gitflow/GitFlowForGitHub.html)

##### Fixing bugs or writing new features

**Starting a new feature branch**

`git hf feature start <feature-name>`

**Returning to a feature branch from another branch**

`git hf feature checkout <feature-name>`

**Pushing a feature to GitHub for collaborative development**

`git hf push`

**Pulling a colleague's work down from GitHub to your feature branch.**

`git hf pull`

**Pulling down the latest `master` and `develop` branches from GitHub**

`git hf update`

**Merging changes onto your feature branch from develop**

* `git hf feature checkout <feature-name>`
* `git merge develop`

**Getting your feature merged into the develop branch**

* `git hf update`
* `git hf feature checkout <feature-name>`
* `git merge develop` (and resolve any merge conflicts)
* `git hf push`
* Open a [pull request](https://help.github.com/articles/using-pull-requests/) to pull changes from your feature branch to `develop` and assign to Curt Mayer \(cmayer68\)
* If any changes are required before your pull request gets merged, commit them to your feature request branch and `git hf push` them to github.  They will be added automatically to your pull request.
* Once your pull request has been merged, run `git hf feature finish` to close your feature branch.

##### Handling pull requests

##### Publishing a new release

