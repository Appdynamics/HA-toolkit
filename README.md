# HA
Appdynamics HA Controller provisioning subsystem

## Non-developer installation & use
* HA Toolkit *must* be installed from `HA.shar`
* Download HA.shar from https://github.com/Appdynamics/HA-toolkit/releases/latest or clone this repository and then run `make` to build a fresh HA.shar

## v4.3 controllers
* ensure you download and install at least HA Toolkit version 3.26 for v4.3 controllers

## Documentation
See [README.txt](README.txt) and https://docs.appdynamics.com/display/PRO42/Using+the+High+Availability+(HA)+Toolkit

## Contributing

### Use HubFlow to manage development branches and releases

Git Flow automates [a number of excellent conventions for managing branches, merges, and releases](http://nvie.com/posts/a-successful-git-branching-model/).  HubFlow is a GitHub-aware fork of the original Git Flow project:

* Easily installed on Mac OS X via homebrew 
* Documentation: http://datasift.github.io/gitflow/

The Git Flow / Hubflow workflow maintains a pair of branches: `develop` and `master`:

* `develop` contains every merged feature and bug fix.
* `master` only contains released, production-ready code.  Bug fixes or features are branched from develop and then merged back in.

***Please note that only Curt Mayer, the project architect, has push privileges to the*** `develop` ***and*** `master` ***branches in this repository.***  To get your features and fixes merged into `develop` and released into `master`, please follow the procedures below.

### Getting started with HA toolkit development

**AppDynamics GitHub organization members:**

* Install hubflow (`brew install hubflow` on Macs with [Homebrew](http://brew.sh) installed, follow the instructions [here](https://github.com/datasift/gitflow) for other platforms.)
* Clone this repo from GitHub with SSH
* Change directories into your clone of the HA-toolkit repo and run `git hf init`
* Please see [Datasift's excellent tutorial on HubFlow](http://datasift.github.io/gitflow/GitFlowForGitHub.html)

**Others:**

* Fork this repository on GitHub
* Clone your forked repository to your development machine.
* Use your preferred version control workflow, push back to your forked repo, and open a pull request on GitHub.  We will evaluate your contributions as we have the bandwidth to do so.

### Common HubFlow / GitHub operations

**Starting a new feature (or bugfix) branch**

`git hf feature start <feature-name>`

**Returning to a feature branch from another branch**

`git hf feature checkout <feature-name>`

This command also works for checking out a feature started by a colleague.  Note that you will need to look [here](https://github.com/Appdynamics/HA-toolkit/branches) for the correct `feature/<feature name>` branch.

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
* Open a [pull request](https://help.github.com/articles/using-pull-requests/) to pull changes from your feature branch to `develop` and assign to Curt Mayer (cmayer68)
* If any changes are required before your pull request gets merged, commit them to your feature request branch and `git hf push` them to github.  They will be added automatically to your pull request.
* Once your pull request has been merged, delete your feature branch from GitHub and run `git hf feature finish` to close your feature branch.  If this fails and you are certain that your feature has been merged, run `git hf feature finish -f <feature name>` to force the cleanup to complete.

**Handling pull requests**

* Open the pull request and review the "Conversation," "Commits," and "Files changed" tabs.
* Make comments, as necessary, on the submitted code changes.  (Unfortunately, that GitHub's comment system isn't as slick as Gerrit's where you can highlight a section of code and attach a comment it to it.  You should place your comment *below* all of the code you are commenting on to improve readability in the "Conversation" tab)
* New commits based on your feedback will be reflected automatically in the pull request, though a browser refresh may be required.
* Once you are satisfied with all of the changes, scroll to the end of the conversation and click the "Merge pull request" button.
* Enter a commit message
* Decide whether to [preserve all of the commits in the pull request, or squash them into a single commit.](https://help.github.com/articles/about-pull-request-merge-squashing/)
* Click the green button again to confirm your selection.

**Publishing a new release**

* `git hf release start <tag name>` (Note that the `<tag name>` should be your version string, i.e. '1.2.3')
* Complete pre-release tests and bug fixes on the relese candidate branch
* `git hf release finish <tag name>`
