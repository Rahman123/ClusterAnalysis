/*
 * Initializes centroids using k-means++ algorithm and loads sample random records for K-Medoids
 *
 * @author: Iskander Mukhamedgaliyev
 */
public with sharing class ClusterInitCentroidsStep implements ClusterAlgorithmStep {
    ClusterKMeansJobState jobState;
    Boolean cacheRecords;
    ClusterAlgorithmRunner algRunner;
    public static Logger log = LogFactory.getLogger();

    public ClusterInitCentroidsStep() {

    }

    public ClusterInitCentroidsStep(Boolean loadInMemory) {
        this.cacheRecords = loadInMemory;
    }

    public void init(ClusterAlgorithmRunner runner) {
        log.debug('Starting init centroids step');
        this.jobState = (ClusterKMeansJobState)runner.getJobState();
        this.algRunner = runner;

        jobState.sampleResultsIds = new List<Id>();
        jobState.centroids = new List<ClusterDataPoint>();
        jobState.dataPoints = new List<ClusterDataPoint>();
        jobState.dataPointsIdMap = new Map<String, Integer>();
    }
    
    private List<ClusterJobResult__c> getRandomRecords(Integer count) {
        ClusterAccessCheck.checkCRUDPermission(Schema.SObjectType.ClusterJobResult__c);
        //isAccessible permission is checked in ClusterAccessCheck.checkReadPermission, exception is thrown in case of no access
        return [SELECT Id, Cluster__c, Json__c, RecordId__c, RecordName__c, ClusterNumber__c, ClusterJob__c FROM ClusterJobResult__c WHERE ClusterJob__c = :this.jobState.clusterJob.Id ORDER BY Random__c LIMIT :count];
    }

    private ClusterDataPoint createDataPoint(ClusterJobResult__c resultRecord) {
        ClusterDataPoint dp = new ClusterDataPoint();
        dp.recordId = resultRecord.Id;
        dp.externalId = resultRecord.RecordId__c;
        dp.values = (Object[])JSON.deserializeUntyped(resultRecord.Json__c);
        ClusterDataHelper.normalizeObject(dp.values, this.jobState);
        return dp;
    }

    public void run() {
        log.debug('Retrieving random records from db');
        List<ClusterJobResult__c> randomRecords = this.getRandomRecords(Math.min(ClusterConstants.getSampleRecordSize(this.jobState.model), this.jobState.numRecords));

        log.debug('Initializing sample records');
        Integer index=0;
        List<ClusterDataPoint> dataPoints = new List<ClusterDataPoint>();
        for (ClusterJobResult__c record:randomRecords){
            this.jobState.sampleResultsIds.add(record.Id);
            ClusterDataPoint dp = this.createDataPoint(record);
            dataPoints.add(dp);
            if (this.cacheRecords) {
                jobState.dataPointsIdMap.put(dp.recordId, index);
            }
            index++;
        }
        //k-means++ centroid initialization
        log.debug('Initializing centroids');
        //Select first centroid randomly
        Integer centroidIndex = ClusterDataHelper.getRandomInt(0, dataPoints.size() - 1);
        this.jobState.centroids.add(dataPoints[centroidIndex]);
        //Select remaining centroids
        for (centroidIndex=0; centroidIndex < this.jobState.model.numberOfClusters - 1; centroidIndex++) {
            Double maxDistance = 0;
            Integer maxCentroid = 0;
            for (Integer dpIndex = 0; dpIndex < dataPoints.size(); dpIndex++) {
                //Compute distance from current data point to each selected centroid
                //And choose the minimum distance
                Double minDistance = this.algRunner.calculateDistance(dataPoints[dpIndex].values, this.jobState.centroids[0].values);
                Boolean isCentroid = false;
                for (Integer cIndex = 1; cIndex < this.jobState.centroids.size(); cIndex++){
                    if (this.jobState.centroids[cIndex].recordId == dataPoints[dpIndex].recordId) {
                        isCentroid = true;
                        break;
                    }
                    Double distance = this.algRunner.calculateDistance(dataPoints[dpIndex].values, this.jobState.centroids[cIndex].values);
                    minDistance = Math.min(minDistance, distance);
                }
                if (!isCentroid && (minDistance > maxDistance)) {
                    maxDistance = minDistance;
                    maxCentroid = dpIndex;
                }
            }
            //Select data point with maximum distance as next centroid
            //we will not calculate probabilities as per k-means++ to save Apex CPU time
            //dp with maximum distance has more chances to become a centroid anyways
            this.jobState.centroids.add(dataPoints[maxCentroid]);
        }

        if (this.cacheRecords) {
            //For K-Medoids we will cache records in memory
            //Since we are using CLARA algorithm the number of records should fit in 12M heap (async mode)
            this.jobState.dataPoints = dataPoints;
        }
        log.debug('Init centroids step finished');
        log.debug('initial centroids: ' + this.jobState.centroids);
    }

    public void done(){
        this.algRunner.processNextSteps();
    }

    public Boolean isAsync(){
        return false;
    } 
}
