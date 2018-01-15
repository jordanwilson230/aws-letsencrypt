Note:
- During execution, any new or updated certificates are immediately uploaded to S3 (see below for setup).
- To ensure idempotent execution, a md5 check is performed against the ELB assigned to the certificste (retrieved via API) and the certificates residing in the s3 bucket. ELBs with a matching value will then not be touched.
- This uses the DNS-01 validation method.
- Lastly, this is a somewhat rushed repo :D ...I'm simply uploading this "as-is" for safekeeping and for others to use/build upon.


### SETUP ###
# Requirements
  Requires AWS credentials with access to Route53, with permissions
  to list zones, and to create and delete records in zones.
  
  Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables, or
  Create ~/.aws/credentials file with [default] credentials, or
  Set AWS_PROFILE to name of credentials entry in ~/.aws/credentials

  Included in Repo:
  * dehydrated
  * Requires cli53 (Will be installed automatically if not found)
  * jq (binary included in repo...place it in your PATH and give executable permissions.)


# Configuration
Feel free to modify the code to your own setup.  It is currently setup for my own personal use, so you will need to modify the script to point to your own s3 bucket.  The following is an example of what the directory structure looks like for our preprod environment.

s3://bitbrew-ssl-certificates/preprod/dehydrated/certs/marathon-preprod.bitbrew.com/

Inside the s3://bitbrew-ssl-certificates/preprod/dehydrated/certs/ directory, simply create a folder for every certificate you will need for that environment (see the above example...and note that you may need to upload something to the directory (a blank file will do) in order for the aws cli to see the folder if it is new.

Inside the s3://bitbrew-ssl-certificates/preprod/dehydrated/ directory, upload the files:
  * config
  * dehydrated
  * hook.sh

# Run
On any linux box (which has permissions to access s3 and Route53) run the update-certificates.sh file.

Follow the prompts to specify the environment you wish to update/renew.

Any certs that are not ready for renewal will be skipped, otherwise updated (or if it sees a blank folder, it creates a new certificate request). The challenge response is handled automatically. 

Once it has finished running, it will upload everything back to the s3 bucket.

For ELB's which are assigned the certificate, they will be automatically discovered and reloaded with the now-updated certificate.

* To prevent downtime, the new cert is first uploaded as yourCertName-tmp. The ELB is immediately assigned this temporary certificate, after which the old certificate is deleted and replaced with the new certificate. The LB then switches back and the temporary certificate deleted.
