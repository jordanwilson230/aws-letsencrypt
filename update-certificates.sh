#!/bin/bash

#region=$(/opt/puppetlabs/bin/facter region)
#environment=$(/opt/puppetlabs/bin/facter environment)
#[[ "$environment" =~ "infra" ]] && environment='production'
#[ -z "$environment" ] && echo -e "\n\nCould Not Detect Environment. Exiting.\n\n" >>/var/log/renew-ssl-certificates.log && exit 1
rm -rf /etc/dehydrated/*
#region='us-east-1'
#environment='production'

echo "Which Region?"
read region
echo "Which Environment?"
read environment

which cli53
if [ $? -ne 0 ]; then
	wget https://github.com/barnybug/cli53/releases/download/0.8.8/cli53-linux-amd64
	mv cli53-linux-amd64 /usr/local/bin/cli53
	chmod +x /usr/local/bin/cli53
fi

echo -e "$(date)\n- Download S3 SSL Certificates\n" >> /var/log/renew-ssl-certificates.log
aws s3 cp s3://bitbrew-ssl-certificates/${environment}/ /etc/ --recursive 1>/dev/null
chmod +x /etc/dehydrated/dehydrated
chmod +x /etc/dehydrated/hook.sh

echo -e "\n- Attempting to Renew Certificates\n" >> /var/log/renew-ssl-certificates.log
for url in $(ls -1 /etc/dehydrated/certs); do
	/etc/dehydrated/dehydrated -c -d ${url} >> /var/log/renew-ssl-certificates.log
done

echo -e "\n\n- Uploading Certificates Back to S3\n" >> /var/log/renew-ssl-certificates.log
aws s3 cp /etc/dehydrated/certs/ s3://bitbrew-ssl-certificates/${environment}/dehydrated/certs/ --recursive 1>/dev/null

echo -e "\n\n- Verifying Current ELB Certificates\n" >> /var/log/renew-ssl-certificates.log
for url in $(ls -1 /etc/dehydrated/certs); do
	unset old_md5 new_md5 ssl_arn elb_names
	aws iam get-server-certificate --region "$region" \
	--server-certificate-name "$url" 1>/dev/null 2>/dev/null
# If cert does not yet exist, just upload it and done.
	if [ $? -ne 0 ]; then
		echo -e "\nUploading New Certificate for ${url}!" >> /var/log/renew-ssl-certificates.log
		aws iam upload-server-certificate --server-certificate-name ${url} --certificate-body file:///etc/dehydrated/certs/${url}/cert.pem  --private-key file:///etc/dehydrated/certs/${url}/privkey.pem --certificate-chain file:///etc/dehydrated/certs/${url}/chain.pem 1>/dev/null 2>> /var/log/renew-ssl-certificates.log
	else
		old_md5=$(aws iam get-server-certificate --region "$region" --server-certificate-name "$url" | jq -r '.ServerCertificate | .CertificateBody' | md5sum | cut -d ' ' -f1)
		new_md5=$(md5sum /etc/dehydrated/certs/${url}/cert.pem | cut -d ' ' -f1)

		if [[ "$old_md5" != "$new_md5" ]]; then
		     # First retrieve the SSL Arn which we will then use to get the names of those ELBs that are currently using the cert.
			ssl_arn=$(aws iam get-server-certificate --region "$region" --server-certificate-name "$url" | jq -r '.ServerCertificate | .ServerCertificateMetadata | .Arn')

			IFS=$'\n'
			declare -A elb_names
			for elb_region in 'us-east-1' 'us-west-2' 'eu-west-1'; do
				elb_names["$elb_region"]=$(aws elb describe-load-balancers --region ${elb_region} | jq '.LoadBalancerDescriptions[] | select(.ListenerDescriptions[].Listener.SSLCertificateId=="'${ssl_arn}'")' | jq -r '.LoadBalancerName')
			done

                        echo -e "\n\n\n- ELB(s) ${elb_names[@]} Require(s) an Update\nLocal md5sum: ${old_md5}\nS3 md5sum:    ${new_md5}\n" >> /var/log/renew-ssl-certificates.log

			aws iam delete-server-certificate --server-certificate-name ${url}-tmp 2>/dev/null
			sleep 30
			aws iam upload-server-certificate --server-certificate-name ${url}-tmp --certificate-body file:///etc/dehydrated/certs/${url}/cert.pem  --private-key file:///etc/dehydrated/certs/${url}/privkey.pem --certificate-chain file:///etc/dehydrated/certs/${url}/chain.pem 1>/dev/null 2>> /var/log/renew-ssl-certificates.log
			sleep 30

			for elb_region in ${!elb_names[@]}; do
				for name in ${elb_names[$elb_region]}; do
				[ ! -z "$name" ] && echo -e "\n\n- Temporarily assign ELB $name Listener to ${url}-tmp\n" && aws elb set-load-balancer-listener-ssl-certificate --region "$elb_region" --load-balancer-name "$name" --load-balancer-port 443 --ssl-certificate-id ${ssl_arn}-tmp >> /var/log/renew-ssl-certificates.log
				done
			done
			sleep 30

		      # We are uploading (and then deleting) the "-tmp" cert in order to prevent any downtime wherein the elb is not associated with a certificate...even if only for a couple of seconds.
			aws iam delete-server-certificate --server-certificate-name ${url}
			sleep 12
			echo -e "\n\n- Uploading the Renewed Certificate\n" >> /var/log/renew-ssl-certificates.log
			aws iam upload-server-certificate --server-certificate-name ${url} --certificate-body file:///etc/dehydrated/certs/${url}/cert.pem  --private-key file:///etc/dehydrated/certs/${url}/privkey.pem --certificate-chain file:///etc/dehydrated/certs/${url}/chain.pem >> /var/log/renew-ssl-certificates.log
			sleep 30

			for elb_region in ${!elb_names[@]}; do
				for name in ${elb_names[$elb_region]}; do
				[ ! -z "$name" ] && echo -e "\nRe-attach ELB $name to ${url}\n" && aws elb set-load-balancer-listener-ssl-certificate --region "$elb_region" --load-balancer-name "$name" --load-balancer-port 443 --ssl-certificate-id ${ssl_arn} >> /var/log/renew-ssl-certificates.log
				done
			done

			sleep 30
			echo -e "\n\n- Remove ${url}-tmp certificate\n" && aws iam delete-server-certificate --server-certificate-name ${url}-tmp  >> /var/log/renew-ssl-certificates.log
			[ $? -eq 0 ] && echo -e "\n- Finished updating SSL Certificate for ${url}\n\n\n" >> /var/log/renew-ssl-certificates.log
		else
			echo -e "\n- SSL Certificate Unchanged for ${url}\nLocal md5sum: ${old_md5}\nS3 md5sum:    ${new_md5}\n" >> /var/log/renew-ssl-certificates.log
		fi
	fi
done
