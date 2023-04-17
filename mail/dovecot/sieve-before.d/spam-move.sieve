require ["fileinto", "imap4flags"];

if header :contains "X-Spam" "Yes" {
  setflag "\\Seen";
  fileinto "Spam";
  stop;
}
