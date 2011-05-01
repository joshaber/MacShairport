# MacShairport
[Shairport](https://github.com/albertz/shairport) is this great thing that lets a computer pretend to be an Airport Express speaker. That means one computer can send audio from its iTunes to be played on another computer. Awesome, right? Except the Shairport server itself is written in Perl and has dependencies that make it hard for normal people to use and install.

## So what?
MacShairport is a native re-implementation of Shairport for Mac. That means any Mac user could download a build and run it on their computer without having to worry about Perl modules and dependencies. Win.

## Does it work?
Yes! Mostly. It seems to be pretty temperamental (underruns) depending on your network configuration but it does work. I'm hoping to improve that soon.

## How can I help?
The biggest problem right now is that hairtunes underruns a lot depending on your network configuration. It'd be awesome if we could improve that.

## License
New BSD License. See LICENSE.txt. Basically, do whatever you want with it but don't blame me for anything that goes wrong and don't remove my license.
