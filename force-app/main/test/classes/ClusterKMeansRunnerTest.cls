@isTest
public with sharing class ClusterKMeansRunnerTest {
    @TestSetup
    static void createLeads(){
        List<sObject> leads = Test.loadData(Lead.sObjectType, 'ClustanLeadsMock');
    }

    @isTest
    public static void testKMeans() {        
        ClusterModelWrapper model = ClusterTestData.createModel('{"algorithm":"K-Means","fields":[{"name":"AnnualRevenue","displayLabel":"Annual Revenue","relationName":"","objectName":"Lead","distanceType":"Numeric","weight":1},{"name":"Id","displayLabel":"Lead ID","relationName":"","objectName":"Lead","distanceType":"None","weight":1},{"name":"Name","displayLabel":"Full Name","relationName":"","objectName":"Lead","distanceType":"None","weight":1},{"name":"NumberOfEmployees","displayLabel":"Employees","relationName":"","objectName":"Lead","distanceType":"Numeric","weight":1}],"filter":"{\\"expressionFields\\":[],\\"customLogic\\":\\"\\"}","isCustomSoql":false,"name":"LeadsUnitTest","numberOfClusters":5,"objectName":"Lead","soql":"SELECT AnnualRevenue, Id, Name, NumberOfEmployees FROM Lead ORDER BY Id LIMIT 50"}');
        User clusterUser = ClusterTestData.createClusterUser();
        System.runAs(clusterUser) {
            ClusterKMeansRunner runner = (ClusterKMeansRunner)ClusterAlgorithmFactory.getRunner(model);
            model.parameters.put('numberOfClusters', 5);
            model.parameters.put('distanceFunction', ClusterConstants.DISTANCE_EUCLIDEAN);
            ClusterAlgorithmRunner.ModelValidationResult vr = runner.validateModel(model);
            System.assertEquals(true, vr.isValid, 'Model validation has failed');

            runner.init(model);
            Test.startTest();
            runner.start();
            Test.stopTest();
            ClusterKMeansJobState state = (ClusterKMeansJobState)ClusterAlgorithmRunner.jobState;
            String stateJson = ClusterJobManager.loadJobState(state.clusterJob.Id);
            System.assertEquals(true, stateJson != null, 'Cluster saved job state is null');
            System.assertEquals(state.model.numberOfClusters, state.jobClusters.size(), 'Incorrect number of clusters created for the job');
            //state = (ClusterKMeansJobState)JSON.deserialize(stateJson, ClusterKMeansJobState.class);

            System.assertEquals(true, state.clusterJob != null, 'Cluster job was not created');
            System.assertEquals(1, state.currentAlgorithmStep, 'Incorrect current step');
            System.assertEquals(state.model.fields.size(), state.minMaxValues.size(), 'MinMax values initialized incorrectly');
            System.debug('MinMax values: ' + state.minMaxValues);
            System.assertEquals(true, (Decimal)state.minMaxValues[0].maxValue > 0, 'MinMax value calculated incorrectly');
            List<ClusterJobResult__c> results = [SELECT Id, Random__c, Json__c FROM ClusterJobResult__c WHERE ClusterJob__c = :state.clusterJob.Id LIMIT 1];
            System.assertEquals(true, results != null && results.size() > 0, 'Job results are not populated');
            System.assertEquals(true, results[0].Random__c >= 0, 'Incorrect random seed value');
            System.assertEquals(true, results[0].Json__c != null && results[0].Json__c != '', 'Json data is not populated');

            //ClusterInitCentroidsStep
            runner.setJobState(state);
            runner.runCurrentStep();        
            
            state = (ClusterKMeansJobState)ClusterAlgorithmRunner.jobState;
            System.assertEquals(state.model.numberOfClusters, state.centroids.size(), 'Centroids initialized incorrectly');

            stateJson = JSON.serialize(state);

            runner.setJobState(state);
            //ClusterCentroidDataAssignmentStep
            Integer currentStep = state.currentAlgorithmStep;
            Integer dataAssignmentStepIndex = currentStep;
            ClusterCentroidDataAssignmentStep dataAssignmentStep = (ClusterCentroidDataAssignmentStep)runner.steps[state.currentAlgorithmStep];
            dataAssignmentStep.init(runner);
            // Get a query locator
            Database.QueryLocator ql = dataAssignmentStep.start(null);
            // Get an iterator
            Database.QueryLocatorIterator it =  ql.iterator();
            List<ClusterJobResult__c> resultScope = new List<ClusterJobResult__c>();
            while (it.hasNext())
            {
                resultScope.add((ClusterJobResult__c)it.next());
            }
            dataAssignmentStep.execute(null, resultScope);
            dataAssignmentStep.finish(null);
            System.assertEquals(dataAssignmentStepIndex + 1, state.currentAlgorithmStep, 'Incorrect next step after data assignment');
            System.assertEquals(true, state.hasAssignmentChanged, 'There was no centroid assignment change');

            //ClusterKMeansCentroidUpdateStep
            currentStep = state.currentAlgorithmStep;
            ClusterKMeansCentroidUpdateStep centroidUpdateStep = (ClusterKMeansCentroidUpdateStep)runner.steps[state.currentAlgorithmStep];
            centroidUpdateStep.init(runner);
            // Get a query locator
            ql = centroidUpdateStep.start(null);
            // Get an iterator
            it = ql.iterator();
            resultScope = new List<ClusterJobResult__c>();
            while (it.hasNext())
            {
                resultScope.add((ClusterJobResult__c)it.next());
            }
            centroidUpdateStep.execute(null, resultScope);
            centroidUpdateStep.finish(null);

            System.assertEquals(dataAssignmentStepIndex, state.currentAlgorithmStep, 'Incorrect next step if there was assignment change');
            
            state.hasAssignmentChanged = false;
            state.currentAlgorithmStep = dataAssignmentStepIndex; //Setting current step back to assignment step
            runner.processNextSteps();
            System.assertEquals(currentStep + 1, state.currentAlgorithmStep, 'Incorrect next step if there is no assignment change');

            //ClusterSilhouetteScoreStep
            currentStep = state.currentAlgorithmStep;
            ClusterSilhouetteScoreStep scoreStep = (ClusterSilhouetteScoreStep)runner.steps[state.currentAlgorithmStep];
            scoreStep.init(runner);
            scoreStep.start(null);
            scoreStep.execute(null, state.dataPoints);
            scoreStep.finish(null);
            System.assertEquals(true, state.clusterJob.Score__c != null, 'Silhouette score calculated incorrectly');

            Boolean lastStep = runner.prepareNextStep();        
            System.assertEquals(true, lastStep, 'Last step not returned');

            results = [SELECT Id, ClusterNumber__c, Cluster__c FROM ClusterJobResult__c WHERE ClusterJob__c = :state.clusterJob.Id LIMIT 1];
            System.assertEquals(true, results[0].ClusterNumber__c >= 0, 'Cluster result cluster number not saved');
            System.assertEquals(true, results[0].Cluster__c != null, 'Cluster result cluster id not saved');
            System.assertEquals(ClusterConstants.JOBSTATUS_COMPLETED, state.clusterJob.JobStatus__c, 'Incorrect job status on last step');

            //Testing ClusterJobDetailsController
            ClusterJobDetailsUiModel jobDetailModel = ClusterJobDetailsController.getJob(state.clusterJob.Id);
            System.assertEquals(state.clusterJob.JobStatus__c, jobDetailModel.status, 'Unexpected job status retrieved');
            
            List<ClusterDataPoint> clusterDataPoints = ClusterJobDetailsController.getDataPoints(state.clusterJob.Id);
            System.assertEquals(true, clusterDataPoints.size() > 0, 'No data points retrieved');
        }
    }

    @isTest 
    static void testJobOutputStep() {
        //The idea of this test is to run first 3 steps of K-Means to populate results with some cluster ids 
        //and then run and test job output step with skipFieldNameCheck=false so it is able to update standard fields
        String modelJson = '{"algorithm":"K-Means","fields":[{"name":"AnnualRevenue","displayLabel":"Annual Revenue","relationName":"","objectName":"Lead","distanceType":"Numeric","weight":1},{"name":"Id","displayLabel":"Lead ID","relationName":"","objectName":"Lead","distanceType":"None","weight":1}' 
        + ',{"name":"Name","displayLabel":"Full Name","relationName":"","objectName":"Lead","distanceType":"None","weight":1},{"name":"NumberOfEmployees","displayLabel":"Employees","relationName":"","objectName":"Lead","distanceType":"Numeric","weight":1}'
        + '],"filter":"{\\"expressionFields\\":[],\\"customLogic\\":\\"\\"}","isCustomSoql":false,"name":"LeadsUnitTest","numberOfClusters":5,"objectName":"Lead","soql":"SELECT AnnualRevenue, Id, Name, NumberOfEmployees, Company FROM Lead LIMIT 200"}';
        
        ClusterModelWrapper model = ClusterTestData.createModel(modelJson);
        User clusterUser = ClusterTestData.createClusterUser();
        System.runAs(clusterUser) {
            ClusterModelFieldWrapper outputField = new ClusterModelFieldWrapper();
            outputField.name = 'Company';
            outputField.displayLabel = 'Company'; 
            outputField.objectName = 'Lead'; 
            outputField.distanceType = 'Output';
            outputField.weight = 1;
            outputField.relationName = '';
            outputField.isIdField = false;
            outputField.isNameField = false;
            outputField.isCategory = false;
            outputField.isNumeric = false;
            outputField.isText = false;
            model.fields.add(outputField);
            ClusterKMeansRunner runner = (ClusterKMeansRunner)ClusterAlgorithmFactory.getRunner(model);
            model.parameters.put('numberOfClusters', 5);
            model.parameters.put('distanceFunction', ClusterConstants.DISTANCE_MANHATTAN);
            runner.init(model);
            Test.startTest();
            runner.start();
            Test.stopTest();

            ClusterKMeansJobState state = (ClusterKMeansJobState)ClusterAlgorithmRunner.jobState;

            //ClusterInitCentroidsStep
            runner.setJobState(state);
            runner.runCurrentStep();        
            
            state = (ClusterKMeansJobState)ClusterAlgorithmRunner.jobState;
            System.assertEquals(state.model.numberOfClusters, state.centroids.size(), 'Centroids initialized incorrectly');

            runner.setJobState(state);
            //ClusterCentroidDataAssignmentStep
            Integer currentStep = state.currentAlgorithmStep;
            Integer dataAssignmentStepIndex = currentStep;
            ClusterCentroidDataAssignmentStep dataAssignmentStep = (ClusterCentroidDataAssignmentStep)runner.steps[state.currentAlgorithmStep];
            dataAssignmentStep.init(runner);
            // Get a query locator
            Database.QueryLocator ql = dataAssignmentStep.start(null);
            // Get an iterator
            Database.QueryLocatorIterator it =  ql.iterator();
            List<ClusterJobResult__c> resultScope = new List<ClusterJobResult__c>();
            while (it.hasNext())
            {
                resultScope.add((ClusterJobResult__c)it.next());
            }
            dataAssignmentStep.execute(null, resultScope);
            dataAssignmentStep.finish(null);
            
            //Testing job output step
            ClusterJobOutputStep outputStep = (ClusterJobOutputStep)runner.steps.get(runner.steps.size() - 1);
            outputStep.init(runner);
            outputStep.skipFieldNameCheck = true; //Skip field name validation check
            ql = outputStep.start(null);
            // Get an iterator
            it =  ql.iterator();
            List<SObject> outputScope = new List<SObject>();
            while (it.hasNext())
            {
                outputScope.add((SObject)it.next());
            }
            outputStep.execute(null, outputScope);
            outputStep.done();

            List<Lead> updatedLeads = Database.query(model.soql);
            for (Lead lead:updatedLeads) {
                System.assertEquals(true, Integer.valueOf(lead.Company) < 5 && Integer.valueOf(lead.Company) >= 0, 'Output field populated incorrectly');
            }
        }
    }
}
