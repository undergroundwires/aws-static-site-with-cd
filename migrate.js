'use strict';

const acm = require('@aws-sdk/client-acm');

const client = new client.ACMClient({
    region: properties.CertificateRegion, retryMode: 'adaptive' })

const log = (t) => console.log(t);

exports.handler = async (event, context) => {
    log(`Request received:\n${JSON.stringify(event)}`);
    const userData = event.ResourceProperties;
    const rootDomain = userData.RootDomainName;
    let data = null;
        try {
            switch(event.RequestType) {
            case 'Create':
                data = await handleCreateAsync(rootDomain, userData.Tags);
                break;
            case 'Update':
                data = await handleUpdateAsync();
                break;
            case 'Delete':
                data = await handleDeleteAsync(rootDomain);
                break;
            }
            await sendResponseAsync(event, context, 'SUCCESS', data);
        } catch(error) {
            await sendResponseAsync(event, context, 'ERROR', {
            title: `Failed to ${event.RequestType}, see error`,
            error: error
            });
        }
}

async function handleCreateAsync(rootDomain, tags) {
    const { CertificateArn } = await client.send(
        new acm.RequestCertificateCommand({
            DomainName: rootDomain,
            SubjectAlternativeNames: [`www.${rootDomain}`],
            ValidationMethod: "DNS",
            Tags: tags,
        }),
    )
    log(`Cert requested:${CertificateArn}`);
    const waitAsync = (ms) => new Promise(resolve => setTimeout(resolve, ms));
    const maxAttempts = 10;
    let options = undefined;
    for (let attempt = 0; attempt < maxAttempts && !options; attempt++) {
        await waitAsync(2000);
        const { Certificate } = await client.send(
            new acm.DescribeCertificateCommand({
                CertificateArn,
            }),
        )
        if(Certificate.DomainValidationOptions.filter((o) => o.ResourceRecord).length === 2) {
            options = Certificate.DomainValidationOptions;
        }
    }
    if(!options) {
        throw new Error(`No records after ${maxAttempts} attempts.`);
    }
    return getResponseData(options, CertificateArn, rootDomain);
}

async function handleDeleteAsync(rootDomain) {
    const certs = await client.send(
        new acm.ListCertificatesCommand({}),
    )
    const cert = certs.CertificateSummaryList.find((cert) => cert.DomainName === rootDomain);
    if (cert) {
        await client.send(
            new acm.DeleteCertificateCommand({
                CertificateArn: cert.CertificateArn,
            }),
        )
        log(`Deleted ${cert.CertificateArn}`);
    } else {
        log('Cannot find'); // Do not fail, delete can be called when e.g. CF fails before creating cert
    }
    return null;
}

async function handleUpdateAsync() {
    log(`Update not implemented`);
}

function getResponseData(options, arn, rootDomain) {
    const findRecord = (url) => options.find(option => option.DomainName === url).ResourceRecord;
    const root = findRecord(rootDomain);
    const www = findRecord(`www.${rootDomain}`);
    const data = {
        CertificateArn: arn,
        RootVerificationRecordName: root.Name,
        RootVerificationRecordValue: root.Value,
        WwwVerificationRecordName: www.Name,
        WwwVerificationRecordValue: www.Value,
    };
    return data;
}

/* cfn-response can't async / await :( */
async function sendResponseAsync(event, context, responseStatus, responseData, physicalResourceId) {
    return new Promise((s, f) => {
        var b = JSON.stringify({
        Status: responseStatus,
        Reason: `See the details in CloudWatch Log Stream: ${context.logStreamName}`,
        PhysicalResourceId: physicalResourceId || context.logStreamName,
        StackId: event.StackId,
        RequestId: event.RequestId,
        LogicalResourceId: event.LogicalResourceId,
        Data: responseData
        });
        log(`Response body:\n${b}`);
        var u = require("url").parse(event.ResponseURL);
        var r = require("https").request(
        {
            hostname: u.hostname,
            port: 443,
            path: u.path,
            method: "PUT",
            headers: {
            "content-type": "",
            "content-length": b.length
            }
        }, (p) => {
            log(`Status code: ${p.statusCode}`);
            log(`Status message: ${p.statusMessage}`);
            s(context.done());
        });
        r.on("error", (e) => {
        log(`request failed: ${e}`);
        f(context.done(e));
        });
        r.write(b);
        r.end();
    });
}
