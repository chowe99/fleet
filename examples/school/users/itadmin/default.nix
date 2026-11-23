# The school's IT administrator: the only account that can use sudo.
{
  description = "IT Administrator";
  extraGroups = ["wheel"];
}
